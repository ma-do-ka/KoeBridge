import base64
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
from validate_update_feed import NS, validate

class FeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'KoeBridge-v1.1.4b-macOS-universal-development.zip'
        self.archive.write_bytes(b'test-only-not-an-app')
        self.feed = self.root / 'appcast.xml'
        # Only structural validation is tested. These bytes are not a signature.
        self.signature = base64.b64encode(bytes(range(64))).decode()
        self.xml = f'''<rss xmlns:sparkle="{NS}"><channel><item><sparkle:version>33</sparkle:version><sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion><enclosure url="https://github.com/ma-do-ka/KoeBridge/releases/download/v1.1.4b/{self.archive.name}" length="{self.archive.stat().st_size}" sparkle:edSignature="{self.signature}" /></item></channel></rss>'''
        self.feed.write_text(self.xml)
    def run_validate(self): validate(self.feed, self.archive, '1.1.4b', '33')
    def changed(self, old, new): self.feed.write_text(self.xml.replace(old,new))
    def test_valid_normalizes_visible_label(self):
        self.run_validate(); root = ET.parse(self.feed)
        self.assertEqual(root.findtext(f'./channel/item/{{{NS}}}shortVersionString'), '1.1.4b')
    def test_numeric_build_preserved(self):
        self.run_validate(); self.assertEqual(ET.parse(self.feed).findtext(f'./channel/item/{{{NS}}}version'), '33')
    def test_untrusted_host_rejected(self):
        self.changed('https://github.com/', 'https://example.org/')
        with self.assertRaises(ValueError): self.run_validate()
    def test_http_rejected(self):
        self.changed('https://github.com/', 'http://github.com/')
        with self.assertRaises(ValueError): self.run_validate()
    def test_wrong_build_rejected(self):
        self.changed('>33<','>32<')
        with self.assertRaises(ValueError): self.run_validate()
    def test_changed_archive_rejected(self):
        self.archive.write_bytes(b'changed')
        with self.assertRaises(ValueError): self.run_validate()
    def test_missing_signature_rejected(self):
        self.changed(self.signature, '')
        with self.assertRaises(ValueError): self.run_validate()
    def test_short_signature_rejected(self):
        self.changed(self.signature, base64.b64encode(b'x').decode())
        with self.assertRaises(ValueError): self.run_validate()
    def test_entity_rejected(self):
        self.feed.write_text('<!DOCTYPE rss [<!ENTITY x "x">]>' + self.xml)
        with self.assertRaises(ValueError): self.run_validate()
    def test_nonstable_channel_rejected(self):
        self.changed('<item>', '<item><sparkle:channel>beta</sparkle:channel>')
        with self.assertRaises(ValueError): self.run_validate()
    def test_multiple_enclosures_rejected(self):
        self.changed('</item>','<enclosure /></item>')
        with self.assertRaises(ValueError): self.run_validate()
    def test_invalid_version_rejected(self):
        with self.assertRaises(ValueError): validate(self.feed,self.archive,'../../other','33')
    def test_symlink_archive_rejected(self):
        real = self.root / 'real'; self.archive.rename(real); self.archive.symlink_to(real)
        with self.assertRaises(ValueError): self.run_validate()
    def test_no_unsigned_external_release_notes(self):
        self.changed('</item>', '<sparkle:releaseNotesLink>https://example.org</sparkle:releaseNotesLink></item>')
        self.run_validate()
        self.assertIsNone(ET.parse(self.feed).find(f'./channel/item/{{{NS}}}releaseNotesLink'))
    def test_minimum_os_normalized(self):
        self.run_validate()
        self.assertEqual(ET.parse(self.feed).findtext(f'./channel/item/{{{NS}}}minimumSystemVersion'), '15.0.0')
    def test_invalid_minimum_os_rejected(self):
        self.changed('>15.0<','>12.0<')
        with self.assertRaises(ValueError): self.run_validate()

if __name__ == '__main__': unittest.main()
