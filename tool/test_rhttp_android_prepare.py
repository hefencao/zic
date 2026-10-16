#!/usr/bin/env python3
"""Check pinned dependency preparation without using a machine's pub cache."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import prepare_rhttp_android as prepare


class RhttpAndroidPrepareTest(unittest.TestCase):
    def test_known_source_is_patched_once(self) -> None:
        source = b'prefix\n' + prepare.ORIGINAL + b'suffix\n'
        expected = b'prefix\n' + prepare.REPLACEMENT + b'suffix\n'
        with tempfile.TemporaryDirectory(prefix='zic-rhttp-prepare-') as temporary:
            plugin = Path(temporary) / 'plugin.gradle'
            plugin.write_bytes(source)
            with patch.object(prepare, 'UPSTREAM_SHA256', hashlib.sha256(source).hexdigest()), \
                 patch.object(prepare, 'PATCHED_SHA256', hashlib.sha256(expected).hexdigest()):
                self.assertTrue(prepare.prepare_plugin(plugin))
                self.assertEqual(plugin.read_bytes(), expected)
                modified = plugin.stat().st_mtime_ns
                self.assertFalse(prepare.prepare_plugin(plugin))
                self.assertEqual(plugin.stat().st_mtime_ns, modified)

    def test_unknown_source_is_preserved_and_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix='zic-rhttp-prepare-') as temporary:
            plugin = Path(temporary) / 'plugin.gradle'
            plugin.write_bytes(b'changed dependency')
            with self.assertRaisesRegex(RuntimeError, 'unrecognized'):
                prepare.prepare_plugin(plugin)
            self.assertEqual(plugin.read_bytes(), b'changed dependency')

    def test_resolved_package_path_and_version_are_authoritative(self) -> None:
        with tempfile.TemporaryDirectory(prefix='zic-rhttp-prepare-') as temporary:
            root = Path(temporary)
            package = root / 'pub cache/rhttp'
            package.mkdir(parents=True)
            pubspec = package / 'pubspec.yaml'
            pubspec.write_text('name: rhttp\nversion: 0.18.0\n')
            config = root / 'package_config.json'
            config.write_text(json.dumps({'packages': [
                {'name': 'rhttp', 'rootUri': 'pub%20cache/rhttp'},
            ]}))
            self.assertEqual(prepare.resolve_plugin(config), package / 'cargokit/gradle/plugin.gradle')
            pubspec.write_text('name: rhttp\nversion: 0.19.0\n')
            with self.assertRaisesRegex(RuntimeError, 'pinned version'):
                prepare.resolve_plugin(config)


if __name__ == '__main__':
    unittest.main()
