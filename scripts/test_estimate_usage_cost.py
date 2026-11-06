#!/usr/bin/env python3
"""Synthetic fixtures only. Never access a user's actual usage records."""
from datetime import datetime, timedelta, timezone
import unittest

from estimate_usage_cost import APPLE_EPOCH, JST, render, summarize, timestamp


def stamp(date):
    return (date - APPLE_EPOCH).total_seconds()


def sample(at, engine, seconds, outcome="success", fallback=False):
    return {"at": stamp(at), "engine": engine, "audioSeconds": seconds,
            "outcome": outcome, "fallback": fallback}


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


if __name__ == "__main__":
    unittest.main()
