#!/usr/bin/env python3
"""Compile the actual repository defaults and inspect the product executable."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = ROOT / 'packages/plugin_host_bridge/lib/src/external_plugin_repository_defaults.dart'


class ReleaseRepositoryDefaultsTest(unittest.TestCase):
    def test_product_contains_no_development_repository_urls(self) -> None:
        dart = shutil.which('dart')
        self.assertIsNotNone(dart, 'Dart is required for the product policy check')
        with tempfile.TemporaryDirectory(prefix='zic-release-repositories-') as temporary:
            source = Path(temporary) / 'defaults.dart'
            source.write_text(f"import '{DEFAULTS.as_uri()}';\n" + '''
void main(List<String> args) {
  const defaults = <String>[
    defaultMihonExtensionRepository,
    defaultVeneraSourceRepository,
  ];
  if (args.single == 'release') {
    if (defaults.any((value) => value.isNotEmpty)) {
      throw StateError('Product builds must not bundle repository indexes');
    }
  } else {
    for (final value in defaults) {
      final uri = Uri.parse(value);
      if (uri.scheme != 'https' || uri.host.isEmpty) {
        throw StateError('Development repository shortcut is missing');
      }
      print(value);
    }
  }
}
''')
            development = subprocess.run(
                [dart, 'run', str(source), 'development'],
                capture_output=True, text=True, cwd=temporary,
            )
            self.assertEqual(development.returncode, 0, development.stdout + development.stderr)
            executable = Path(temporary) / 'defaults'
            product = subprocess.run(
                [dart, 'compile', 'exe', '-Ddart.vm.product=true',
                 str(source), '-o', str(executable)],
                capture_output=True, text=True, cwd=temporary,
            )
            self.assertEqual(product.returncode, 0, product.stdout + product.stderr)
            subprocess.run([str(executable), 'release'], check=True)
            binary = executable.read_bytes()
            indexes = development.stdout.splitlines()
            self.assertEqual(len(indexes), 2)
            for index in indexes:
                self.assertNotIn(index.encode(), binary)


if __name__ == '__main__':
    unittest.main()
