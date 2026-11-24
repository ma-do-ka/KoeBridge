#!/usr/bin/env python3
"""Read-only, aggregate KoeBridge usage and estimate paid-tier API cost.

Reads only usage-monitor.json. Never reads transcripts, API keys or diagnostic logs.
No network requests, no writes, and no Cloud Billing attribution.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import json
import math
from pathlib import Path
import re
import sys
from typing import Any

JST = timezone(timedelta(hours=9))
APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
DEFAULT_PATH = Path.home() / "Library/Application Support/KoeBridge/usage-monitor.json"
USD_PER_MINUTE = 0.009  # Google Gemini 3.5 Transcribe Live, paid-tier illustration
AMIVOICE_NOLOG_JPY_PER_SECOND = 0.04125  # AmiVoice WebSocket/Sync nolog General (tax-included)
AMIVOICE_FREE_SECONDS_PER_MONTH = 3600.0  # 60 min/month free VAD speech per individual engine
AMIVOICE_SPEECH_TOLERANCE_SECONDS = 5.0
ENGINE_VARIANT_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
SCALAR_ROW_KEYS = (
    "gemini_calls", "gemini_seconds", "gemini_failures",
    "recheck_calls", "recheck_seconds",
    "apple_calls", "apple_seconds", "fallbacks",
    "amivoice_calls", "amivoice_seconds", "amivoice_speech_seconds",
    "amivoice_speech_fallback_calls", "amivoice_failures",
    "token_reports", "reported_tokens", "missing_prompt", "missing_response",
)


def timestamp(value: object) -> datetime:
    # Swift JSONEncoder default Date encoding: seconds from 2001-01-01 UTC.
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("invalid recorded timestamp")
    try:
        return APPLE_EPOCH + timedelta(seconds=value)
    except (ValueError, OverflowError) as exc:
        raise ValueError("timestamp out of range") from exc


def number(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError("invalid nonnegative number")
    return float(value)


def engine_variant(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not ENGINE_VARIANT_RE.fullmatch(value):
        raise ValueError("invalid engine variant")
    return value


def empty_row() -> dict[str, Any]:
    return {
        "gemini_calls": 0, "gemini_seconds": 0.0, "gemini_failures": 0,
        "recheck_calls": 0, "recheck_seconds": 0.0,
        "apple_calls": 0, "apple_seconds": 0.0, "fallbacks": 0,
        "amivoice_calls": 0, "amivoice_seconds": 0.0,
        "amivoice_speech_seconds": 0.0, "amivoice_speech_fallback_calls": 0,
        "amivoice_failures": 0, "amivoice_by_variant": {},
        "token_reports": 0, "reported_tokens": 0, "missing_prompt": 0, "missing_response": 0,
    }


def summarize(payload: object, now: datetime, days: int = 30) -> dict[str, dict[str, Any]]:
    if not isinstance(payload, dict) or not isinstance(payload.get("engineEvents"), list) or not isinstance(payload.get("tokenEvents"), list):
        raise ValueError("unexpected usage-monitor schema")
    if not 1 <= days <= 365:
        raise ValueError("invalid day count")
    rows: dict[str, dict[str, Any]] = defaultdict(empty_row)
    lower = now - timedelta(days=days)
    upper = now + timedelta(minutes=5)
    for event in payload["engineEvents"]:
        if not isinstance(event, dict):
            raise ValueError("invalid engine event")
        at = timestamp(event.get("at"))
        if not lower <= at <= upper:
            continue
        engine = event.get("engine")
        if engine not in ("gemini", "apple", "amivoice"):
            raise ValueError("unknown engine")
        seconds = number(event.get("audioSeconds"))
        raw_speech = event.get("speechSeconds")
        speech: float | None = None
        if raw_speech is not None:
            speech = number(raw_speech)
            if speech > seconds + AMIVOICE_SPEECH_TOLERANCE_SECONDS:
                raise ValueError("speechSeconds exceeds audioSeconds tolerance")
        variant = engine_variant(event.get("engineVariant"))
        row = rows[at.astimezone(JST).date().isoformat()]
        row[engine + "_calls"] += 1
        row[engine + "_seconds"] += seconds
        if event.get("purpose") == "audioRecheck":
            if engine != "gemini":
                raise ValueError("invalid recheck engine")
            row["recheck_calls"] += 1
            row["recheck_seconds"] += seconds
        if engine == "gemini" and event.get("outcome") == "failure":
            row["gemini_failures"] += 1
        if engine == "apple" and event.get("fallback") is True:
            row["fallbacks"] += 1
        if engine == "amivoice":
            used_fallback = speech is None
            effective_speech = seconds if speech is None else speech
            row["amivoice_speech_seconds"] += effective_speech
            if used_fallback:
                row["amivoice_speech_fallback_calls"] += 1
            if event.get("outcome") == "failure":
                row["amivoice_failures"] += 1
            by_variant = row["amivoice_by_variant"]
            bucket = by_variant.get(variant)
            if bucket is None:
                bucket = {"calls": 0, "audio_seconds": 0.0, "speech_seconds": 0.0, "fallback_calls": 0}
                by_variant[variant] = bucket
            bucket["calls"] += 1
            bucket["audio_seconds"] += seconds
            bucket["speech_seconds"] += effective_speech
            if used_fallback:
                bucket["fallback_calls"] += 1
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


def amivoice_monthly_summary(rows: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str | None], dict[str, Any]] = {}
    for day, row in rows.items():
        month = day[:7]
        by_variant = row.get("amivoice_by_variant")
        if by_variant:
            items = by_variant.items()
        elif row.get("amivoice_calls", 0) > 0:
            items = [(None, {
                "calls": row["amivoice_calls"],
                "audio_seconds": row.get("amivoice_seconds", 0.0),
                "speech_seconds": row.get("amivoice_speech_seconds", row.get("amivoice_seconds", 0.0)),
                "fallback_calls": row.get("amivoice_speech_fallback_calls", 0),
            })]
        else:
            continue
        for variant, stats in items:
            key = (month, variant)
            bucket = grouped.get(key)
            if bucket is None:
                bucket = {"calls": 0, "audio_seconds": 0.0, "speech_seconds": 0.0, "fallback_calls": 0}
                grouped[key] = bucket
            bucket["calls"] += stats["calls"]
            bucket["audio_seconds"] += stats["audio_seconds"]
            bucket["speech_seconds"] += stats["speech_seconds"]
            bucket["fallback_calls"] += stats.get("fallback_calls", 0)

    whole_free = int(math.floor(AMIVOICE_FREE_SECONDS_PER_MONTH))
    summary: list[dict[str, Any]] = []
    for (month, variant), bucket in sorted(grouped.items(), key=lambda item: (item[0][0], item[0][1] is None, item[0][1] or "")):
        speech = max(0.0, float(bucket["speech_seconds"]))
        whole_speech = int(math.floor(speech + 1e-9))
        billable = max(0, whole_speech - whole_free)
        summary.append({
            "month": month,
            "engine_variant": variant,
            "calls": bucket["calls"],
            "audio_seconds": bucket["audio_seconds"],
            "speech_seconds": speech,
            "fallback_calls": bucket["fallback_calls"],
            "free_allowance_seconds": AMIVOICE_FREE_SECONDS_PER_MONTH,
            "free_remaining_seconds": max(0.0, AMIVOICE_FREE_SECONDS_PER_MONTH - speech),
            "billable_seconds": billable,
            "estimated_jpy": billable * AMIVOICE_NOLOG_JPY_PER_SECOND,
        })
    return summary


def render(rows: dict[str, dict[str, Any]], rate: float | None = None, days: int = 30) -> str:
    lines = [
        "KoeBridge ローカル利用統計（直近" + str(days) + "日、日本時間）",
        "Gemini 3.5 Transcribe Live: 有料枠の概算 $0.009/音声1分（典型的な文字出力量を仮定）",
        "AmiVoice API (nolog/汎用): エンジンごとに月60分（3,600秒）のVAD発話無料枠、超過分 ¥0.04125/発話秒（税込・¥2.475/分）",
        "日付 | Gemini回数 | Gemini分 | AmiVoice回数 | AmiVoice音声分 | Apple回数 | 自動切替 | 報告トークン | Live概算USD" + (" | Live概算JPY" if rate is not None else "")
    ]
    grand = empty_row()
    for day, row in rows.items():
        for k in SCALAR_ROW_KEYS:
            grand[k] += row.get(k, 0)
        usd = (row["gemini_seconds"] - row["recheck_seconds"]) / 60 * USD_PER_MINUTE
        tokens = str(row["reported_tokens"]) if row["token_reports"] else "未取得"
        entry = (
            day
            + " | " + str(row["gemini_calls"])
            + " | " + format(row["gemini_seconds"] / 60, ".2f")
            + " | " + str(row.get("amivoice_calls", 0))
            + " | " + format(row.get("amivoice_seconds", 0.0) / 60, ".2f")
            + " | " + str(row["apple_calls"])
            + " | " + str(row["fallbacks"])
            + " | " + tokens
            + " | $" + format(usd, ".4f")
        )
        if rate is not None:
            entry += " | ¥" + format(usd * rate, ".2f")
        lines.append(entry)
    usd = (grand["gemini_seconds"] - grand["recheck_seconds"]) / 60 * USD_PER_MINUTE
    tokens = str(grand["reported_tokens"]) if grand["token_reports"] else "未取得"
    entry = (
        "合計"
        + " | " + str(grand["gemini_calls"])
        + " | " + format(grand["gemini_seconds"] / 60, ".2f")
        + " | " + str(grand["amivoice_calls"])
        + " | " + format(grand["amivoice_seconds"] / 60, ".2f")
        + " | " + str(grand["apple_calls"])
        + " | " + str(grand["fallbacks"])
        + " | " + tokens
        + " | $" + format(usd, ".4f")
    )
    if rate is not None:
        entry += " | ¥" + format(usd * rate, ".2f")
    lines.append(entry)
    lines.append(
        "Gemini失敗試行: " + str(grand["gemini_failures"]) + "回、"
        + "AmiVoice失敗試行: " + str(grand["amivoice_failures"]) + "回、"
        + "Apple処理: " + format(grand["apple_seconds"] / 60, ".2f") + "分"
    )
    monthly = amivoice_monthly_summary(rows)
    if monthly:
        lines.append("AmiVoice月別概算（日本時間・エンジン別60分無料枠控除後・nolog参考単価 ¥0.04125/発話秒）:")
        lines.append("対象月 | エンジン | 回数 | 送信音声秒 | 発話秒(課金基準) | 無料枠残秒 | 超過秒 | 概算JPY")
        total_billable = 0
        total_jpy = 0.0
        for item in monthly:
            total_billable += item["billable_seconds"]
            total_jpy += item["estimated_jpy"]
            label = item["engine_variant"] if item["engine_variant"] is not None else "未指定"
            lines.append(
                item["month"]
                + " | " + label
                + " | " + str(item["calls"])
                + " | " + format(item["audio_seconds"], ".1f")
                + " | " + format(item["speech_seconds"], ".1f")
                + " | " + format(item["free_remaining_seconds"], ".1f")
                + " | " + str(item["billable_seconds"])
                + " | ¥" + format(item["estimated_jpy"], ".2f")
            )
        lines.append(
            "AmiVoice概算合計: 超過 " + str(total_billable) + "秒 / ¥" + format(total_jpy, ".2f")
            + "（発話秒未記録のため音声秒で代替: " + str(grand["amivoice_speech_fallback_calls"]) + "回）"
        )
    else:
        lines.append("AmiVoice利用: 0回（対象期間に記録なし）")
    lines.append("音声の追加チェック: " + str(grand["recheck_calls"]) + "回 / " + format(grand["recheck_seconds"] / 60, ".2f") + "分（非Live API。上記のLive概算額には含めていません。別途料金が発生します）")
    lines.append("usageMetadata報告: " + str(grand["token_reports"]) + "件（入力未取得 " + str(grand["missing_prompt"]) + "件／出力未取得 " + str(grand["missing_response"]) + "件）")
    if rate is not None:
        lines.append("円換算の仮定為替: 1 USD = " + format(rate, ".2f") + "円（自動取得なし）")
    lines.extend([
        "注意: 無音・失敗送信を含む音声秒数に基づく仮定額。実請求ではありません。",
        "注意: API文字出力、無料枠、クレジット、課金遅延、別API利用、為替で実額は変動します。",
        "注意: usageMetadataは累計や重複の可能性があるため料金計算に使っていません。",
        "注意: ローカル利用統計の保持は直近30日間のため、AmiVoice月別無料枠の残量は参考値です。正確な利用量はAmiVoiceマイページで確認してください。",
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
