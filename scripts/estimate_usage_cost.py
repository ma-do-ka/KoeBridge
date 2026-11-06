#!/usr/bin/env python3
"""Read-only, aggregate KoeBridge usage and estimate paid-tier API cost.

Reads only usage-monitor.json. Never reads transcripts, API keys or diagnostic logs.
No network requests, no writes, and no Cloud Billing attribution.
"""
import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import json
import math
from pathlib import Path
import sys

JST = timezone(timedelta(hours=9))
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
DEFAULT_PATH = Path.home() / "Library/Application Support/KoeBridge/usage-monitor.json"
USD_PER_MINUTE = 0.009  # Google Gemini 3.5 Transcribe Live, paid-tier illustration

def timestamp(value):
    # Swift JSONEncoder default Date encoding: seconds from 2001-01-01 UTC.
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("invalid recorded timestamp")
    try:
        return APPLE_EPOCH + timedelta(seconds=value)
    except (ValueError, OverflowError) as exc:
        raise ValueError("timestamp out of range") from exc

def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError("invalid nonnegative number")
    return float(value)

def empty_row():
    return {"gemini_calls": 0, "gemini_seconds": 0.0, "gemini_failures": 0,
            "apple_calls": 0, "apple_seconds": 0.0, "fallbacks": 0,
            "token_reports": 0, "reported_tokens": 0, "missing_prompt": 0, "missing_response": 0}

def summarize(payload, now, days=30):
    if not isinstance(payload, dict) or not isinstance(payload.get("engineEvents"), list) or not isinstance(payload.get("tokenEvents"), list):
        raise ValueError("unexpected usage-monitor schema")
    if not 1 <= days <= 365:
        raise ValueError("invalid day count")
    rows = defaultdict(empty_row)
    lower = now - timedelta(days=days)
    upper = now + timedelta(minutes=5)
    for event in payload["engineEvents"]:
        if not isinstance(event, dict):
            raise ValueError("invalid engine event")
        at = timestamp(event.get("at"))
        if not lower <= at <= upper:
            continue
        engine = event.get("engine")
        if engine not in ("gemini", "apple"):
            raise ValueError("unknown engine")
        seconds = number(event.get("audioSeconds"))
        row = rows[at.astimezone(JST).date().isoformat()]
        row[engine + "_calls"] += 1
        row[engine + "_seconds"] += seconds
        if engine == "gemini" and event.get("outcome") == "failure":
            row["gemini_failures"] += 1
        if engine == "apple" and event.get("fallback") is True:
            row["fallbacks"] += 1
    for event in payload["tokenEvents"]:
        if not isinstance(event, dict):
            raise ValueError("invalid token event")
        at = timestamp(event.get("at"))
        if not lower <= at <= upper:
            continue
        row = rows[at.astimezone(JST).date().isoformat()]
        row["token_reports"] += 1
        row["reported_tokens"] += int(number(event.get("totalTokens")))
        if event.get("promptTokens") is None:
            row["missing_prompt"] += 1
        else:
            number(event["promptTokens"])
        if event.get("responseTokens") is None:
            row["missing_response"] += 1
        else:
            number(event["responseTokens"])
    return dict(sorted(rows.items()))

def render(rows, rate=None, days=30):
    lines = [
        "KoeBridge ローカル利用統計（直近" + str(days) + "日、日本時間）",
        "Gemini 3.5 Transcribe Live: 有料枠の概算 $0.009/音声1分（典型的な文字出力量を仮定）",
        "日付 | Gemini回数 | Gemini分 | Apple回数 | 自動切替 | 報告トークン | 概算USD" + (" | 概算JPY" if rate is not None else "")
    ]
    grand = empty_row()
    for day, row in rows.items():
        for k in grand:
            grand[k] += row[k]
        usd = row["gemini_seconds"] / 60 * USD_PER_MINUTE
        tokens = str(row["reported_tokens"]) if row["token_reports"] else "未取得"
        entry = day + " | " + str(row["gemini_calls"]) + " | " + format(row["gemini_seconds"] / 60, ".2f") + " | " + str(row["apple_calls"]) + " | " + str(row["fallbacks"]) + " | " + tokens + " | $" + format(usd, ".4f")
        if rate is not None:
            entry += " | ¥" + format(usd * rate, ".2f")
        lines.append(entry)
    usd = grand["gemini_seconds"] / 60 * USD_PER_MINUTE
    tokens = str(grand["reported_tokens"]) if grand["token_reports"] else "未取得"
    entry = "合計 | " + str(grand["gemini_calls"]) + " | " + format(grand["gemini_seconds"] / 60, ".2f") + " | " + str(grand["apple_calls"]) + " | " + str(grand["fallbacks"]) + " | " + tokens + " | $" + format(usd, ".4f")
    if rate is not None:
        entry += " | ¥" + format(usd * rate, ".2f")
    lines.append(entry)
    lines.append("Gemini失敗試行: " + str(grand["gemini_failures"]) + "回、Apple処理: " + format(grand["apple_seconds"] / 60, ".2f") + "分")
    lines.append("usageMetadata報告: " + str(grand["token_reports"]) + "件（入力未取得 " + str(grand["missing_prompt"]) + "件／出力未取得 " + str(grand["missing_response"]) + "件）")
    if rate is not None:
        lines.append("円換算の仮定為替: 1 USD = " + format(rate, ".2f") + "円（自動取得なし）")
    lines.extend([
        "注意: 無音・失敗送信を含む音声秒数に基づく仮定額。実請求ではありません。",
        "注意: API文字出力、無料枠、クレジット、課金遅延、別API利用、為替で実額は変動します。",
        "注意: usageMetadataは累計や重複の可能性があるため料金計算に使っていません。",
        "出力には認識本文・APIキー・録音・生ログを含みません。"
    ])
    if not rows:
        lines.append("対象期間に記録なし。APIが未使用であることを保証するものではありません。")
    return chr(10).join(lines)

def main(argv=None):
    parser = argparse.ArgumentParser(description="KoeBridge匿名集計・API概算（読み取り専用）")
    parser.add_argument("--file", type=Path, default=DEFAULT_PATH)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--usd-jpy", type=float, default=None)
    args = parser.parse_args(argv)
    if not 1 <= args.days <= 365:
        parser.error("--days must be between 1 and 365")
    if args.usd_jpy is not None and (not math.isfinite(args.usd_jpy) or args.usd_jpy <= 0):
        parser.error("--usd-jpy must be a positive exchange rate")
    if not args.file.is_file():
        print("利用統計ファイルがありません（未使用とは限りません）。", file=sys.stderr)
        return 2
    try:
        if args.file.stat().st_size > 8 * 1024 * 1024:
            raise ValueError("file exceeds safety limit")
        payload = json.loads(args.file.read_text(encoding="utf-8"))
        rows = summarize(payload, datetime.now(timezone.utc), args.days)
    except (OSError, ValueError, TypeError, OverflowError):
        print("統計の読み取りに失敗しました。ファイルの内容は出力していません。", file=sys.stderr)
        return 2
    print(render(rows, args.usd_jpy, args.days))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
