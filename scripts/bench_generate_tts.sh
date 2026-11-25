#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/bench_generate_tts.sh [output-dir]

Generates the Track 2 macOS TTS corpus outside the repository.
Default output directory: $HOME/.cache/koebridge-bench/audio
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
MANIFEST="$ROOT/Tools/KoeBridgeBench/corpus/manifest.json"
OUTDIR="${1:-$HOME/.cache/koebridge-bench/audio}"
ROOT_ABS="$(cd "$ROOT" && pwd -P)"
OUT_NORM="$(python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$OUTDIR")"
if [ "$OUT_NORM" = "$ROOT_ABS" ] || [[ "$OUT_NORM" == "$ROOT_ABS"/* ]]; then
  echo "ERROR: output directory must be outside the repository: $OUTDIR" >&2
  exit 2
fi

mkdir -p "$OUT_NORM"
OUT_ABS="$(cd "$OUT_NORM" && pwd -P)"
if [ "$OUT_ABS" = "$ROOT_ABS" ] || [[ "$OUT_ABS" == "$ROOT_ABS"/* ]]; then
  echo "ERROR: output directory resolves inside the repository: $OUTDIR" >&2
  exit 2
fi

TMP="$(mktemp -d "$OUT_ABS/.tts-generate.XXXXXX")"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

ROWS="$TMP/track2.tsv"
python3 - "$MANIFEST" > "$ROWS" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)
clips = [clip for clip in manifest.get("clips", []) if clip.get("track") == 2]
if len(clips) != 12:
    raise SystemExit("manifest must contain exactly 12 Track 2 clips")
for clip in clips:
    cid = clip.get("id", "")
    voice = clip.get("voice", "")
    reference = clip.get("reference", "")
    if voice not in {"Kyoko", "Otoya"} or not reference:
        raise SystemExit(f"invalid Track 2 clip metadata: {cid}")
    if "\t" in reference or "\n" in reference or "\r" in reference:
        raise SystemExit(f"reference must be single-line TSV-safe text: {cid}")
    print(f"{cid}\t{voice}\t{reference}")
PY

generated=0
while IFS=$'\t' read -r clip_id voice reference; do
  [ -n "$clip_id" ] || continue
  aiff="$TMP/$clip_id.aiff"
  converted="$TMP/$clip_id.afconvert.wav"
  canonical_tmp="$TMP/$clip_id.canonical.wav"
  final="$OUT_ABS/$clip_id.wav"

  say -v "$voice" -o "$aiff" "$reference"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$converted"
  python3 - "$converted" "$canonical_tmp" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_bytes()
target = Path(sys.argv[2])
if len(source) < 12 or source[0:4] != b"RIFF" or source[8:12] != b"WAVE":
    raise SystemExit("afconvert output is not a RIFF/WAVE file")

fmt = None
pcm = None
pos = 12
while pos + 8 <= len(source):
    chunk_id = source[pos:pos + 4]
    size = int.from_bytes(source[pos + 4:pos + 8], "little")
    pos += 8
    if pos + size > len(source):
        raise SystemExit("afconvert output has a truncated RIFF chunk")
    payload = source[pos:pos + size]
    if chunk_id == b"fmt ":
        fmt = payload
    elif chunk_id == b"data":
        if pcm is not None:
            raise SystemExit("afconvert output has multiple data chunks")
        pcm = payload
    pos += size + (size & 1)

if fmt is None or pcm is None:
    raise SystemExit("afconvert output lacks fmt or data chunk")
if len(fmt) < 16:
    raise SystemExit("afconvert output has a short fmt chunk")
audio_format = int.from_bytes(fmt[0:2], "little")
channels = int.from_bytes(fmt[2:4], "little")
sample_rate = int.from_bytes(fmt[4:8], "little")
bits_per_sample = int.from_bytes(fmt[14:16], "little")
if (audio_format, channels, sample_rate, bits_per_sample) != (1, 1, 16000, 16):
    raise SystemExit(
        "afconvert output is not PCM16LE/16kHz/mono: "
        f"format={audio_format} channels={channels} rate={sample_rate} bits={bits_per_sample}"
    )
if not pcm or len(pcm) % 2:
    raise SystemExit("PCM payload is empty or not sample-aligned")
if len(pcm) > 32_000 * 45:
    raise SystemExit("PCM payload exceeds the benchmark's 45-second clip limit")

def u16(value):
    return value.to_bytes(2, "little")

def u32(value):
    return value.to_bytes(4, "little")

canonical = b"".join([
    b"RIFF", u32(len(pcm) + 36), b"WAVE",
    b"fmt ", u32(16), u16(1), u16(1), u32(16000), u32(32000), u16(2), u16(16),
    b"data", u32(len(pcm)), pcm,
])
target.write_bytes(canonical)
PY
  pcm_sha="$(python3 -c 'import hashlib,sys; data=open(sys.argv[1],"rb").read(); print(hashlib.sha256(data[44:]).hexdigest())' "$canonical_tmp")"
  mv "$canonical_tmp" "$final"
  file_sha="$(shasum -a 256 "$final" | awk '{print $1}')"
  printf '%s\tvoice=%s\tpcm_sha256=%s\tfile_sha256=%s\tpath=%s\n' "$clip_id" "$voice" "$pcm_sha" "$file_sha" "$final"
  generated=$((generated + 1))
done < "$ROWS"

if [ "$generated" -ne 12 ]; then
  echo "ERROR: generated $generated files, expected 12" >&2
  exit 1
fi
printf 'generated=%d\toutput_dir=%s\n' "$generated" "$OUT_ABS"
printf '%s\n' 'Note: manifest sha256 locks are PCM SHA-256 values; file_sha256 is printed only for transport verification.'
