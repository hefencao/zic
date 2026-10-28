#!/usr/bin/env python3
"""Reject assets that cannot safely upgrade the existing public Android beta."""
import unittest
from prepare_beta_release import (ABIS, BETA_CERTIFICATE, beta_version, release_notes,
                                  validate_badging, validate_certificate, validate_native_layout)


class BetaReleaseTest(unittest.TestCase):
    def test_requires_matching_explicit_beta_versions(self):
        self.assertEqual(beta_version('version: 1.2.3-beta.4+350\n',
                         'versionName=1.2.3-beta.4\nversionCode=350'), ('1.2.3-beta.4', '350'))
        for version, android in [('1.2.3+350', '1.2.3'), ('1.2.3-beta.4+350', '1.2.3-beta.3'),
                                 ('1.2.3-beta.4+0', '1.2.3-beta.4')]:
            with self.assertRaises(ValueError):
                beta_version(f'version: {version}', f'versionName={android}\nversionCode=350')

    def test_notes_do_not_include_other_versions(self):
        text = '## 1.2.3-beta.4\n\n- New feature\n\n## 1.2.3-beta.3\n- Old feature'
        self.assertEqual(release_notes(text, '1.2.3-beta.4'), '- New feature\n')
        with self.assertRaises(ValueError):
            release_notes(text, '1.2.3-beta.5')

    def test_rejects_wrong_identity_version_and_debug_build(self):
        good = "package: name='dev.zic.zic' versionCode='350' versionName='1.2.3-beta.4'\n"
        validate_badging(good, '1.2.3-beta.4', '350')
        for bad in [good.replace('dev.zic.zic', 'example.other'), good.replace('350', '349'),
                    good.replace('350', '2350'),
                    good.replace('beta.4', 'beta.3'), good + 'application-debuggable\n']:
            with self.assertRaises(ValueError):
                validate_badging(bad, '1.2.3-beta.4', '350')

    def test_rejects_different_missing_or_additional_signer(self):
        good = f'Signer #1 certificate SHA-256 digest: {BETA_CERTIFICATE}\n'
        validate_certificate(good)
        for bad in ['', good.replace(BETA_CERTIFICATE, '0' * 64), good + good.replace('#1', '#2')]:
            with self.assertRaises(ValueError):
                validate_certificate(bad)

    def test_rejects_mislabeled_splits_and_missing_runtime(self):
        for abi in ABIS:
            good = [f'lib/{abi}/{name}.so' for name in ['libapp', 'libflutter', 'libmedia_core', 'librhttp']]
            validate_native_layout(good, abi)
            for bad in [[], good[:-1], good + ['lib/other/libflutter.so']]:
                with self.assertRaises(ValueError):
                    validate_native_layout(bad, abi)

    def test_accepts_build_tools_37_scheme_labels_without_accepting_extra_signers(self):
        v2 = f'V2 Signer: certificate SHA-256 digest: {BETA_CERTIFICATE}\n'
        validate_certificate(v2)
        validate_certificate(v2 + v2.replace('V2', 'V3'))
        for bad in [v2 + v2, v2 + v2.replace('Signer:', 'Signer #2:'),
                    v2 + v2.replace('V2', 'V3').replace(BETA_CERTIFICATE, '0' * 64)]:
            with self.assertRaises(ValueError):
                validate_certificate(bad)


if __name__ == '__main__':
    unittest.main()
