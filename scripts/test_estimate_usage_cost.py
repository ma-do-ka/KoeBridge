#!/usr/bin/env python3
"""Synthetic fixtures only. Never access a user's actual usage records."""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
import io
import json
from pathlib import Path
import tempfile
import unittest

from estimate_usage_cost import (
    AMIVOICE_NOLOG_JPY_PER_SECOND,
    APPLE_EPOCH,
    JST,
    MAX_RETENTION_SECONDS,
    amivoice_monthly_summary,
    main,
    render,
    summarize,
    timestamp,
)


def stamp(date: datetime) -> float:
    return (date - APPLE_EPOCH).total_seconds()


def sample(
    at: datetime,
    engine: str,
    seconds: float,
    outcome: str = "success",
    fallback: bool = False,
    speech_seconds: float | None = None,
    engine_variant: str | None = None,
) -> dict[str, object]:
    record: dict[str, object] = {
        "at": stamp(at),
        "engine": engine,
        "audioSeconds": seconds,
        "outcome": outcome,
        "fallback": fallback,
    }
    if speech_seconds is not None:
        record["speechSeconds"] = speech_seconds
    if engine_variant is not None:
        record["engineVariant"] = engine_variant
    return record


class CostEstimateTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 6, 10, 30, tzinfo=timezone.utc)

    def test_swift_reference_date_and_jst_midnight(self):
        at = datetime(2026, 11, 5, 15, 30, tzinfo=timezone.utc)
        self.assertEqual(timestamp(stamp(at)).astimezone(JST).date().isoformat(), "2026-11-06")

    def test_counts_audio_minutes_fallback_failure_and_cost(self):
        at = self.now - timedelta(hours=2)
        rows = summarize({
            "engineEvents": [
                sample(at, "gemini", 120),
                sample(at, "gemini", 60, outcome="failure"),
                sample(at, "apple", 120, fallback=True),
            ],
            "tokenEvents": [
                {"at": stamp(at), "totalTokens": 1000, "promptTokens": 800, "responseTokens": 200}
            ],
        }, self.now)
        row = next(iter(rows.values()))
        self.assertEqual(row["gemini_calls"], 2)
        self.assertEqual(row["gemini_seconds"], 180)
        self.assertEqual(row["gemini_failures"], 1)
        self.assertEqual(row["apple_calls"], 1)
        self.assertEqual(row["fallbacks"], 1)
        self.assertEqual(row["reported_tokens"], 1000)
        self.assertIn("$0.0270 | ¥4.27", render(rows, 158, 30))

    def test_expired_and_future_events_not_charged(self):
        old = self.now - timedelta(days=31)
        future = self.now + timedelta(days=1)
        rows = summarize({
            "engineEvents": [sample(old, "gemini", 600), sample(future, "gemini", 360)],
            "tokenEvents": [],
        }, self.now)
        self.assertEqual(rows, {})

    def test_optional_recheck_is_counted_but_not_priced_as_live(self):
        rows = summarize({
            "engineEvents": [sample(self.now, "gemini", 60),
                             dict(sample(self.now, "gemini", 60), purpose="audioRecheck")],
            "tokenEvents": [],
        }, self.now)
        row = next(iter(rows.values()))
        self.assertEqual(row["gemini_calls"], 2)
        self.assertEqual(row["recheck_calls"], 1)
        self.assertEqual(row["gemini_seconds"], 120)
        self.assertIn("$0.0090", render(rows))
        self.assertIn("追加チェック: 1回 / 1.00分", render(rows))

    def test_partial_metadata_marked_missing(self):
        rows = summarize({
            "engineEvents": [],
            "tokenEvents": [{"at": stamp(self.now), "totalTokens": 50,
                             "promptTokens": None, "responseTokens": None}],
        }, self.now)
        row = next(iter(rows.values()))
        self.assertEqual(row["missing_prompt"], 1)
        self.assertEqual(row["missing_response"], 1)

    def test_no_secret_or_transcript_leaked(self):
        private_text = "DO_NOT_PRINT_PRIVATE_TRANSCRIPT"
        rows = summarize({
            "engineEvents": [dict(sample(self.now, "gemini", 60),
                                  transcript=private_text, apiKey=private_text)],
            "tokenEvents": [],
            "recent_transcripts": private_text,
        }, self.now)
        self.assertNotIn(private_text, render(rows, 158, 30))

    def test_rejects_invalid_schema_and_negative_audio(self):
        with self.assertRaises(ValueError):
            summarize({"engineEvents": [], "tokenEvents": None}, self.now)
        with self.assertRaises(ValueError):
            summarize({"engineEvents": [sample(self.now, "gemini", -1)], "tokenEvents": []}, self.now)
        with self.assertRaises(ValueError):
            timestamp(float("nan"))

    def test_amivoice_vad_speech_seconds_and_silence_vs_fallback(self) -> None:
        at = self.now - timedelta(hours=1)
        rows = summarize({
            "engineEvents": [
                sample(at, "amivoice", 120, speech_seconds=80, engine_variant="-a2-ja-general"),
                # Silence-only take: speechSeconds == 0.0 must NOT fall back to audioSeconds
                sample(at, "amivoice", 30, speech_seconds=0.0, engine_variant="-a2-ja-general"),
                # Untagged failure without speechSeconds falls back to audioSeconds
                sample(at, "amivoice", 45, outcome="failure"),
            ],
            "tokenEvents": [],
        }, self.now)
        row = next(iter(rows.values()))
        self.assertEqual(row["amivoice_calls"], 3)
        self.assertEqual(row["amivoice_seconds"], 195.0)
        self.assertEqual(row["amivoice_speech_seconds"], 125.0)
        self.assertEqual(row["amivoice_speech_fallback_calls"], 1)
        self.assertEqual(row["amivoice_failures"], 1)

        monthly = amivoice_monthly_summary(rows)
        self.assertEqual(len(monthly), 2)
        self.assertEqual(monthly[0]["engine_variant"], "-a2-ja-general")
        self.assertEqual(monthly[0]["audio_seconds"], 150.0)
        self.assertEqual(monthly[0]["speech_seconds"], 80.0)
        self.assertEqual(monthly[0]["fallback_calls"], 0)
        self.assertEqual(monthly[0]["billable_seconds"], 0)
        self.assertEqual(monthly[0]["free_remaining_seconds"], 3520.0)
        self.assertEqual(monthly[0]["estimated_jpy"], 0.0)

        self.assertIsNone(monthly[1]["engine_variant"])
        self.assertEqual(monthly[1]["speech_seconds"], 45.0)
        self.assertEqual(monthly[1]["fallback_calls"], 1)
        self.assertEqual(monthly[1]["billable_seconds"], 0)

        rendered = render(rows, 158, 30)
        self.assertIn("-a2-ja-general", rendered)
        self.assertIn("未指定", rendered)
        self.assertIn("AmiVoice失敗試行: 1回", rendered)
        self.assertIn("音声秒で代替: 1回", rendered)

    def test_amivoice_free_tier_per_engine_and_whole_second_floor(self) -> None:
        at = self.now - timedelta(hours=2)
        rows = summarize({
            "engineEvents": [
                # -a2-ja-general: 3600 + 300.9 = 3900.9 speech s -> floors to 3900 -> 300 billable s -> ¥12.375
                sample(at, "amivoice", 2200, speech_seconds=2000, engine_variant="-a2-ja-general"),
                sample(at, "amivoice", 2000, speech_seconds=1900.9, engine_variant="-a2-ja-general"),
                # -a2b-ja-general gets its own independent 3600 s free bucket -> 3600.9 floors to 3600 -> 0 billable
                sample(at, "amivoice", 3700, speech_seconds=3600.9, engine_variant="-a2b-ja-general"),
            ],
            "tokenEvents": [],
        }, self.now)
        monthly = amivoice_monthly_summary(rows)
        self.assertEqual(len(monthly), 2)
        self.assertEqual(monthly[0]["engine_variant"], "-a2-ja-general")
        self.assertEqual(monthly[0]["billable_seconds"], 300)
        self.assertAlmostEqual(monthly[0]["estimated_jpy"], 300 * AMIVOICE_NOLOG_JPY_PER_SECOND, places=9)
        self.assertEqual(monthly[1]["engine_variant"], "-a2b-ja-general")
        self.assertEqual(monthly[1]["billable_seconds"], 0)
        self.assertEqual(monthly[1]["estimated_jpy"], 0.0)

        rendered = render(rows, 158, 30)
        self.assertIn("2026-11 | -a2-ja-general | 2 | 4200.0 | 3900.9 | 0.0 | 300 | ¥12.38", rendered)
        self.assertIn("2026-11 | -a2b-ja-general | 1 | 3700.0 | 3600.9 | 0.0 | 0 | ¥0.00", rendered)
        self.assertIn("超過 300秒 / ¥12.38", rendered)

    def test_amivoice_free_tier_resets_across_jst_calendar_months(self) -> None:
        # 2026-10-31 14:59:59 UTC == 2026-10-31 23:59:59 JST
        oct_end = datetime(2026, 10, 31, 14, 59, 59, tzinfo=timezone.utc)
        # 2026-10-31 15:00:00 UTC == 2026-11-01 00:00:00 JST
        nov_start = datetime(2026, 10, 31, 15, 0, 0, tzinfo=timezone.utc)
        rows = summarize({
            "engineEvents": [
                sample(oct_end, "amivoice", 3500, speech_seconds=3500, engine_variant="-a2-ja-general"),
                sample(nov_start, "amivoice", 3500, speech_seconds=3500, engine_variant="-a2-ja-general"),
            ],
            "tokenEvents": [],
        }, self.now)
        monthly = amivoice_monthly_summary(rows)
        self.assertEqual([(m["month"], m["billable_seconds"], m["free_remaining_seconds"]) for m in monthly], [
            ("2026-10", 0, 100.0),
            ("2026-11", 0, 100.0),
        ])

    def test_amivoice_float_sum_drift_preserves_exact_billable_second(self) -> None:
        at = self.now - timedelta(minutes=10)
        # 10 * 360.1 in binary IEEE 754 can drift slightly under 3601.0; must still bill 1 s
        events = [
            sample(at, "amivoice", 370.0, speech_seconds=360.1, engine_variant="-a2-ja-general")
            for _ in range(10)
        ]
        rows = summarize({"engineEvents": events, "tokenEvents": []}, self.now)
        monthly = amivoice_monthly_summary(rows)
        self.assertEqual(monthly[0]["billable_seconds"], 1)
        self.assertAlmostEqual(monthly[0]["estimated_jpy"], AMIVOICE_NOLOG_JPY_PER_SECOND, places=12)

    def test_rejects_invalid_amivoice_fields_and_recheck(self) -> None:
        # Negative speechSeconds
        with self.assertRaises(ValueError):
            summarize({"engineEvents": [sample(self.now, "amivoice", 10, speech_seconds=-0.1)], "tokenEvents": []}, self.now)
        # speechSeconds exceeding audioSeconds + 5 tolerance
        with self.assertRaises(ValueError):
            summarize({"engineEvents": [sample(self.now, "amivoice", 10, speech_seconds=15.1)], "tokenEvents": []}, self.now)
        # Bool or NaN speechSeconds
        with self.assertRaises(ValueError):
            summarize({"engineEvents": [dict(sample(self.now, "amivoice", 10), speechSeconds=True)], "tokenEvents": []}, self.now)
        with self.assertRaises(ValueError):
            summarize({"engineEvents": [sample(self.now, "amivoice", 10, speech_seconds=float("nan"))], "tokenEvents": []}, self.now)
        # Invalid engineVariant (empty, whitespace, non-string, >64 bytes)
        for bad_variant in ("", "bad variant", "line1\nline2", 123, "a" * 65):
            with self.assertRaises(ValueError):
                summarize(
                    {"engineEvents": [dict(sample(self.now, "amivoice", 10), engineVariant=bad_variant)], "tokenEvents": []},
                    self.now,
                )
        # audioRecheck is Gemini-only
        with self.assertRaises(ValueError):
            summarize(
                {"engineEvents": [dict(sample(self.now, "amivoice", 10), purpose="audioRecheck")], "tokenEvents": []},
                self.now,
            )

    def test_accepts_durations_exactly_at_retention_cap_and_per_record_aggregate(self) -> None:
        self.assertEqual(MAX_RETENTION_SECONDS, 2_592_000.0)
        at = self.now - timedelta(hours=1)
        rows = summarize({
            "engineEvents": [
                sample(at, "amivoice", MAX_RETENTION_SECONDS, speech_seconds=MAX_RETENTION_SECONDS, engine_variant="-a2-ja-general"),
                sample(at, "amivoice", MAX_RETENTION_SECONDS, engine_variant="-a2b-ja-general"),
                sample(at, "gemini", MAX_RETENTION_SECONDS),
                sample(at, "apple", MAX_RETENTION_SECONDS),
            ],
            "tokenEvents": [],
        }, self.now)
        row = next(iter(rows.values()))
        self.assertEqual(row["amivoice_seconds"], 2 * MAX_RETENTION_SECONDS)
        self.assertEqual(row["amivoice_speech_seconds"], 2 * MAX_RETENTION_SECONDS)
        self.assertEqual(row["amivoice_speech_fallback_calls"], 1)
        self.assertEqual(row["gemini_seconds"], MAX_RETENTION_SECONDS)
        self.assertEqual(row["apple_seconds"], MAX_RETENTION_SECONDS)

        monthly = amivoice_monthly_summary(rows)
        self.assertEqual(len(monthly), 2)
        expected_billable = int(MAX_RETENTION_SECONDS) - 3600
        for bucket in monthly:
            self.assertEqual(bucket["billable_seconds"], expected_billable)
            self.assertAlmostEqual(bucket["estimated_jpy"], expected_billable * AMIVOICE_NOLOG_JPY_PER_SECOND, places=9)

        # Cap is per-record (matching Swift EngineUsageSample.hasValidDuration), not aggregate.
        multi_rows = summarize({
            "engineEvents": [
                sample(at, "amivoice", 2_000_000, speech_seconds=2_000_000, engine_variant="-a2-ja-general"),
                sample(at, "amivoice", 2_000_000, speech_seconds=2_000_000, engine_variant="-a2-ja-general"),
            ],
            "tokenEvents": [],
        }, self.now)
        multi_monthly = amivoice_monthly_summary(multi_rows)
        self.assertEqual(multi_monthly[0]["speech_seconds"], 4_000_000.0)
        self.assertEqual(multi_monthly[0]["billable_seconds"], 4_000_000 - 3600)

    def test_rejects_durations_over_retention_cap_by_one_second(self) -> None:
        over_cap = MAX_RETENTION_SECONDS + 1
        # Reported finding: audioSeconds at cap, speechSeconds 1s over cap (within +5s tolerance)
        for bad_event in (
            sample(self.now, "amivoice", MAX_RETENTION_SECONDS, speech_seconds=over_cap, engine_variant="-a2-ja-general"),
            sample(self.now, "amivoice", MAX_RETENTION_SECONDS, speech_seconds=MAX_RETENTION_SECONDS + 0.01),
            sample(self.now, "amivoice", MAX_RETENTION_SECONDS - 2, speech_seconds=over_cap),
            sample(self.now, "amivoice", over_cap),
            sample(self.now, "amivoice", over_cap, speech_seconds=10),
            sample(self.now, "amivoice", over_cap, speech_seconds=MAX_RETENTION_SECONDS),
            sample(self.now, "gemini", over_cap),
            sample(self.now, "apple", over_cap),
            sample(self.now, "gemini", MAX_RETENTION_SECONDS, speech_seconds=over_cap),
        ):
            with self.subTest(event=bad_event):
                with self.assertRaises(ValueError):
                    summarize({"engineEvents": [bad_event], "tokenEvents": []}, self.now)

        # Retention cap is fixed at 30 days even when --days is larger than 30.
        with self.assertRaises(ValueError):
            summarize(
                {"engineEvents": [sample(self.now, "amivoice", MAX_RETENTION_SECONDS, speech_seconds=over_cap)], "tokenEvents": []},
                self.now,
                days=365,
            )
        with self.assertRaises(ValueError):
            summarize(
                {"engineEvents": [sample(self.now, "amivoice", over_cap)], "tokenEvents": []},
                self.now,
                days=365,
            )

        # CLI fails closed with no billed output on an over-cap record.
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            bad_file = Path(tmp) / "over_cap.json"
            bad_file.write_text(json.dumps({
                "engineEvents": [
                    sample(now - timedelta(minutes=1), "amivoice", MAX_RETENTION_SECONDS, speech_seconds=over_cap, engine_variant="-a2-ja-general"),
                ],
                "tokenEvents": [],
            }), encoding="utf-8")
            out = io.StringIO()
            err = io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = main(["--file", str(bad_file), "--days", "30"])
            self.assertEqual(code, 2)
            self.assertEqual(out.getvalue(), "")
            self.assertIn("読み取りに失敗しました", err.getvalue())

    def test_speech_seconds_greater_than_audio_seconds_boundaries(self) -> None:
        at = self.now - timedelta(hours=1)
        # Valid when speechSeconds > audioSeconds within +5s tolerance and <= retention cap.
        rows = summarize({
            "engineEvents": [
                sample(at, "amivoice", 10, speech_seconds=15, engine_variant="-a2-ja-general"),
                sample(at, "amivoice", 0, speech_seconds=5, engine_variant="-a2-ja-general"),
                sample(at, "amivoice", MAX_RETENTION_SECONDS - 2, speech_seconds=MAX_RETENTION_SECONDS, engine_variant="-a2b-ja-general"),
            ],
            "tokenEvents": [],
        }, self.now)
        monthly = amivoice_monthly_summary(rows)
        self.assertEqual(monthly[0]["engine_variant"], "-a2-ja-general")
        self.assertEqual(monthly[0]["audio_seconds"], 10.0)
        self.assertEqual(monthly[0]["speech_seconds"], 20.0)
        self.assertEqual(monthly[1]["engine_variant"], "-a2b-ja-general")
        self.assertEqual(monthly[1]["audio_seconds"], MAX_RETENTION_SECONDS - 2)
        self.assertEqual(monthly[1]["speech_seconds"], MAX_RETENTION_SECONDS)

        # Rejected when speechSeconds exceeds audioSeconds + 5 or the retention cap.
        for audio_s, speech_s in (
            (10, 15.01),
            (10, 16),
            (0, 5.01),
            (MAX_RETENTION_SECONDS - 2, MAX_RETENTION_SECONDS + 1),
            (MAX_RETENTION_SECONDS, MAX_RETENTION_SECONDS + 1),
        ):
            with self.subTest(audio_seconds=audio_s, speech_seconds=speech_s):
                with self.assertRaises(ValueError):
                    summarize(
                        {"engineEvents": [sample(self.now, "amivoice", audio_s, speech_seconds=speech_s)], "tokenEvents": []},
                        self.now,
                    )

    def test_legacy_rows_without_amivoice_keys_render_cleanly(self) -> None:
        legacy_rows = {
            "2026-11-06": {
                "gemini_calls": 1, "gemini_seconds": 60.0, "gemini_failures": 0,
                "recheck_calls": 0, "recheck_seconds": 0.0,
                "apple_calls": 1, "apple_seconds": 30.0, "fallbacks": 0,
                "token_reports": 0, "reported_tokens": 0, "missing_prompt": 0, "missing_response": 0,
            }
        }
        output = render(legacy_rows, 158, 30)
        self.assertIn("$0.0090 | ¥1.42", output)
        self.assertIn("AmiVoice利用: 0回", output)

    def test_cli_handles_legacy_and_amivoice_usage_files(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            legacy_file = Path(tmp) / "legacy.json"
            legacy_file.write_text(json.dumps({
                "engineEvents": [sample(now - timedelta(minutes=5), "gemini", 60)],
                "tokenEvents": [],
            }), encoding="utf-8")
            buf = io.StringIO()
            with redirect_stdout(buf):
                code = main(["--file", str(legacy_file), "--days", "30", "--usd-jpy", "158"])
            self.assertEqual(code, 0)
            self.assertIn("$0.0090 | ¥1.42", buf.getvalue())
            self.assertIn("AmiVoice利用: 0回", buf.getvalue())

            mixed_file = Path(tmp) / "mixed.json"
            mixed_file.write_text(json.dumps({
                "engineEvents": [
                    sample(now - timedelta(minutes=5), "gemini", 60),
                    sample(now - timedelta(minutes=4), "amivoice", 4000, speech_seconds=3700, engine_variant="-a2-ja-general"),
                ],
                "tokenEvents": [],
            }), encoding="utf-8")
            buf2 = io.StringIO()
            with redirect_stdout(buf2):
                code2 = main(["--file", str(mixed_file), "--days", "30", "--usd-jpy", "158"])
            self.assertEqual(code2, 0)
            self.assertIn("-a2-ja-general", buf2.getvalue())
            self.assertIn("超過 100秒 / ¥4.12", buf2.getvalue())


if __name__ == "__main__":
    unittest.main()
