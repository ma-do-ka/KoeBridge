#!/usr/bin/env python3
"""Validate a locally generated single-release feed, before signing it.
Does not download, sign, upload or install anything. Signature authenticity is
verified by Sparkle, not by this structural validation helper.
"""
from __future__ import annotations
import base64
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)

def validate(feed: Path, archive: Path, label: str, build: str) -> None:
    if not re.fullmatch(r'\d+\.\d+\.\d+[a-z]?', label) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('invalid release identity')
    if feed.is_symlink() or archive.is_symlink():
        raise ValueError('symlinks are not release inputs')
    data = feed.read_bytes()
    if len(data) > 1_048_576 or b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ValueError('invalid feed structure')
    root = ET.fromstring(data)
    items = root.findall('./channel/item')
    if root.tag != 'rss' or len(root.findall('channel')) != 1 or len(items) != 1:
        raise ValueError('expected a single-release appcast')
    item = items[0]
    if item.findtext(f'{{{NS}}}version') != build:
        raise ValueError('build does not match the package')
    if item.find(f'{{{NS}}}channel') is not None:
        raise ValueError('only the stable channel is supported')
    enclosures = item.findall('enclosure')
    if len(enclosures) != 1:
        raise ValueError('expected one archive')
    enclosure = enclosures[0]
    expected_name = f'KoeBridge-v{label}-macOS-universal-development.zip'
    expected_url = f'https://github.com/ma-do-ka/KoeBridge/releases/download/v{label}/{expected_name}'
    if archive.name != expected_name or enclosure.get('url') != expected_url:
        raise ValueError('archive URL or filename mismatch')
    if int(enclosure.get('length', '-1')) != archive.stat().st_size or archive.stat().st_size == 0:
        raise ValueError('archive size mismatch')
    signature = base64.b64decode(enclosure.get(f'{{{NS}}}edSignature', ''), validate=True)
    if len(signature) != 64:
        raise ValueError('missing archive signature')
    # The internal CFBundleVersion drives ordering. The visible label keeps b.
    short = item.find(f'{{{NS}}}shortVersionString')
    if short is None: short = ET.SubElement(item, f'{{{NS}}}shortVersionString')
    short.text = label
    minimum = item.find(f'{{{NS}}}minimumSystemVersion')
    if minimum is None: minimum = ET.SubElement(item, f'{{{NS}}}minimumSystemVersion')
    if minimum.text not in (None, '15', '15.0', '15.0.0'):
        raise ValueError('minimum OS mismatch')
    minimum.text = '15.0.0'
    title = item.find('title')
    if title is None: title = ET.SubElement(item, 'title')
    title.text = f'KoeBridge {label} (Build {build})'
    # No externally fetched release notes or extra enclosures are needed.
    for tag in ('releaseNotesLink', 'fullReleaseNotesLink', 'deltas'):
        for node in item.findall(f'{{{NS}}}{tag}'): item.remove(node)
    ET.indent(root)
    feed.write_bytes(ET.tostring(root, encoding='utf-8', xml_declaration=True))

if __name__ == '__main__':
    try:
        if len(sys.argv) != 5: raise ValueError('usage: feed.xml archive.zip label build')
        validate(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4])
    except (ValueError, OSError, ET.ParseError) as error:
        sys.exit(f'ERROR: {error}')
