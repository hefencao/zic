#!/usr/bin/env python3
from __future__ import annotations

import tempfile
from pathlib import Path

from configure_platforms import configure_android_manifest


def main() -> int:
    with tempfile.TemporaryDirectory(prefix='zic-platform-test-') as directory:
        manifest = (
            Path(directory)
            / 'android'
            / 'app'
            / 'src'
            / 'main'
            / 'AndroidManifest.xml'
        )
        manifest.parent.mkdir(parents=True)
        manifest.write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <application android:label="zic" />\n'
            '</manifest>\n',
            encoding='utf-8',
        )

        assert configure_android_manifest(manifest) is True
        assert configure_android_manifest(manifest) is False
        text = manifest.read_text(encoding='utf-8')
        assert text.count('android.permission.INTERNET') == 1
        assert text.index('<uses-permission') < text.index('<application')

    print('generated Android host configuration: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
