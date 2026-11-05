#!/usr/bin/env python3
"""Pre-publish, allowlist-based safety audit. Not a replacement for manual review."""
from pathlib import Path
import hashlib
import os
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'scripts' / 'public_files.txt'
SECRET_PATTERNS = {
    'Google API key': re.compile(r'AIza[0-9A-Za-z_-]{30,}'),
    'GitHub token': re.compile(r'(?:gh[pousr]_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,})'),
    'AWS access key': re.compile(r'AKIA[0-9A-Z]{16}'),
    'Private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'OpenAI-style API key': re.compile(r'sk-(?:proj-)?[0-9A-Za-z_-]{25,}'),
    'Bearer access token': re.compile(r'Bearer\s+[A-Za-z0-9_.\-]{32,}'),
}
RISKY_NAMES = re.compile(r'(?:^\.env(?:\.|$)|\.(?:pem|key|p8|p12|pfx|sqlite|db)$|(?i:credentials|service-account|transcripts|secrets))')
ALLOWED_EXTRA = {'.DS_Store'}
# Reviewed binary artwork only. Every accepted byte must match its pinned Git blob.
# Do not relax the UTF-8 scan for any other file or allow broad binary patterns.
APPROVED_BINARY_BLOBS = {
    'Resources/KoeBridge_AppIcon.icns': 'b3c6586c44da783e823d165b4b4fa4f7b885b740',
    'Resources/KoeBridge_AppIcon_1024.png': 'f5cafb8a82d3496ea3aa8487928b1ebf5e2d7a69',
    'docs/images/koebridge-hero.webp': '1e021eb97928cdc084b997494f9b30b46b6a9141',
}
OMIT_DIRS = {'.git', '.build', 'dist', '.swiftpm', 'DerivedData', '__pycache__'}


def main() -> int:
    errors = []
    if not MANIFEST.is_file():
        print('FAIL: no manifest', file=sys.stderr)
        return 1
    entries = [line.strip() for line in MANIFEST.read_text(encoding='utf-8').splitlines() if line.strip() and not line.startswith('#')]
    if len(set(entries)) != len(entries):
        errors.append('Duplicate entries in allowlist')
    allowed = set(entries)
    for name in entries:
        rel = Path(name)
        if rel.is_absolute() or '..' in rel.parts or name.startswith('.') and name not in {'.gitignore', '.github/workflows/mac-ci.yml', '.github/workflows/release-v1.0.1.yml', '.github/workflows/release-v1.0.1b.yml', '.github/workflows/release-v1.0.1c.yml', '.github/workflows/release-v1.0.1d.yml', '.github/workflows/release-v1.0.1e.yml'}:
            errors.append(f'Unsafe manifest path: {name}')
            continue
        if RISKY_NAMES.search(rel.name):
            errors.append(f'Forbidden file name: {name}')
        file = ROOT / rel
        if file.is_symlink() or not file.is_file():
            errors.append(f'Missing/nonregular/symlink: {name}')
            continue
        try:
            data = file.read_bytes()
            if name in APPROVED_BINARY_BLOBS:
                git_blob = hashlib.sha1(
                    b'blob ' + str(len(data)).encode('ascii') + b'\x00' + data
                ).hexdigest()
                if git_blob != APPROVED_BINARY_BLOBS[name]:
                    errors.append(f'Unapproved binary content: {name}')
                continue
            if b'\x00' in data or len(data) > 1_500_000:
                errors.append(f'Binary/oversized file: {name}')
                continue
            content = data.decode('utf-8')
        except UnicodeDecodeError:
            errors.append(f'Not UTF-8: {name}')
            continue
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(content):
                errors.append(f'Potential {label} found in: {name} (content NOT printed)')
        # Guard against accidental machine-specific absolute home paths.
        if name != 'scripts/audit_public_release.py' and re.search(r'/Users/(?!user/|example/|YOUR_USER/)[^\s/]+/', content):
            errors.append(f'Potential machine-specific home path in: {name}')
    for path in ROOT.rglob('*'):
        rel = path.relative_to(ROOT)
        if any(p in OMIT_DIRS for p in rel.parts):
            continue
        if path.is_symlink():
            errors.append(f'Unexpected symlink: {rel}')
        elif path.is_file() and rel.as_posix() not in allowed and path.name not in ALLOWED_EXTRA:
            errors.append(f'Not on publication allowlist: {rel}')
    if errors:
        for msg in errors:
            print('FAIL:', msg, file=sys.stderr)
        print('Publication blocked. No secrets have been printed.', file=sys.stderr)
        return 1
    print(f'PASS: {len(entries)} approved files, {len(APPROVED_BINARY_BLOBS)} pinned binary artworks; no matched secret patterns or unexpected files.')
    print('LIMITATION: Manual code review and GitHub history review are still necessary.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
