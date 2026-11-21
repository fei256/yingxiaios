"""Exercise platform download/import recovery without requiring Xcode."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[2] / 'Scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('ios_platform', SCRIPTS / 'prepare-ios-platform.py')
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)


class PlatformTests(unittest.TestCase):
    def test_runtime_only_keeps_the_selected_newer_device_sdk(self):
        with mock.patch.object(platform.subprocess, 'check_output', return_value='18.5'), \
             mock.patch.object(platform, 'installed', return_value=True):
            report = platform.install_platform(self.root, '16.1', require_matching_sdk=False)
        self.assertEqual(report['runtime_version'], '16.1')
        self.assertEqual(report['sdk_version'], '18.5')
        self.assertEqual(self.downloads, [])
        self.assertEqual(self.imports, [])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / 'build/ios-platform-cache'
        self.cache.mkdir(parents=True)
        self.archive = self.cache / 'runtime.dmg'
        self.archive.write_bytes(b'cached image')
        self.downloads = []
        self.imports = []
        patches = [mock.patch.object(platform.subprocess, 'check_output', return_value='18.1'),
                   mock.patch.object(platform.subprocess, 'run', side_effect=self.command),
                   mock.patch.object(platform.time, 'sleep'),
                   mock.patch.object(platform, 'installed', side_effect=[False, True]),
                   mock.patch.object(platform, 'verify_dmg', return_value=True)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def command(self, arguments, **kwargs):
        if '-downloadPlatform' in arguments:
            folder = Path(arguments[arguments.index('-exportPath') + 1])
            self.downloads.append(folder)
            (folder / 'runtime.dmg').write_bytes(b'new complete image')
        if '-importPlatform' in arguments:
            self.imports.append(Path(arguments[-1]).read_bytes())
        return subprocess.CompletedProcess(arguments, 0)

    def test_legacy_cache_is_adopted_only_after_import_and_version_check(self):
        report = platform.install_platform(self.root)
        self.assertTrue(report['reused_download'])
        self.assertEqual(self.downloads, [])
        self.assertEqual(self.imports, [b'cached image'])
        self.assertTrue((self.cache / 'platform-receipt.json').is_file())

    def test_corrupt_receipt_refetches_instead_of_reusing_bad_dmg(self):
        (self.cache / 'platform-receipt.json').write_text(json.dumps({'version': '18.1', 'sha256': 'wrong'}))
        report = platform.install_platform(self.root)
        self.assertFalse(report['reused_download'])
        self.assertEqual(len(self.downloads), 1)
        self.assertEqual(self.imports, [b'new complete image'])

    def test_dmg_integrity_failure_refetches(self):
        platform.verify_dmg.side_effect = [False, True]
        platform.install_platform(self.root)
        self.assertEqual(len(self.downloads), 1)
        self.assertEqual(self.imports, [b'new complete image'])

    def test_failed_cached_import_falls_back_to_new_download(self):
        def command(arguments, **kwargs):
            if '-importPlatform' in arguments and Path(arguments[-1]).read_bytes() == b'cached image':
                self.imports.append(b'cached image')
                return subprocess.CompletedProcess(arguments, 1)
            return self.command(arguments, **kwargs)
        platform.subprocess.run.side_effect = command
        report = platform.install_platform(self.root)
        self.assertFalse(report['reused_download'])
        self.assertEqual(self.imports, [b'cached image'] * 3 + [b'new complete image'])

    def test_zero_exit_code_without_required_runtime_is_failure(self):
        platform.installed.side_effect = None
        platform.installed.return_value = False
        with self.assertRaisesRegex(RuntimeError, 'required available runtime'):
            platform.install_platform(self.root)
        self.assertFalse((self.cache / 'platform-receipt.json').exists())

    def test_interrupted_download_uses_a_new_staging_directory(self):
        self.archive.unlink()
        def command(arguments, **kwargs):
            if '-downloadPlatform' in arguments and not self.downloads:
                folder = Path(arguments[arguments.index('-exportPath') + 1])
                self.downloads.append(folder)
                (folder / 'runtime.dmg').write_bytes(b'partial')
                return subprocess.CompletedProcess(arguments, 1)
            return self.command(arguments, **kwargs)
        platform.subprocess.run.side_effect = command
        platform.install_platform(self.root)
        self.assertEqual(len(self.downloads), 2)
        self.assertNotEqual(self.downloads[0], self.downloads[1])
        self.assertEqual(self.imports, [b'new complete image'])
        self.assertFalse(self.downloads[0].exists())

    def test_wrong_sdk_fails_before_download_or_import(self):
        platform.subprocess.check_output.return_value = '26.0'
        with self.assertRaisesRegex(RuntimeError, 'requires 18.1'):
            platform.install_platform(self.root)
        self.assertEqual(self.downloads, [])
        self.assertEqual(self.imports, [])


class DmgValidationTests(unittest.TestCase):
    def verify(self, results):
        with mock.patch.object(platform.subprocess, 'run', side_effect=results) as command, \
             contextlib.redirect_stdout(io.StringIO()):
            valid = platform.verify_dmg(Path('runtime.dmg'))
        return valid, command.call_count

    def test_checksum_bearing_image_must_pass_verify(self):
        valid, calls = self.verify([subprocess.CompletedProcess([], 0, stdout='verified', stderr='')])
        self.assertTrue(valid)
        self.assertEqual(calls, 1)

    def test_apple_export_without_embedded_checksum_accepts_readable_image_metadata(self):
        image = plistlib.dumps({'Format': 'UDRO', 'Properties': {'Checksummed': False}}).decode()
        valid, calls = self.verify([
            subprocess.CompletedProcess([], 1, stdout='', stderr='hdiutil: verify: "runtime.dmg" has no checksum.\n'),
            subprocess.CompletedProcess([], 0, stdout=image, stderr=''),
        ])
        self.assertTrue(valid)
        self.assertEqual(calls, 2)

    def test_actual_checksum_failure_cannot_fall_back_to_metadata_only(self):
        valid, calls = self.verify([subprocess.CompletedProcess([], 1, stdout='', stderr='hdiutil: verify: checksum mismatch\n')])
        self.assertFalse(valid)
        self.assertEqual(calls, 1)

    def test_no_checksum_with_unreadable_metadata_is_rejected(self):
        valid, calls = self.verify([
            subprocess.CompletedProcess([], 1, stdout='', stderr='hdiutil: verify: "runtime.dmg" has no checksum.\n'),
            subprocess.CompletedProcess([], 0, stdout='not an image plist', stderr=''),
        ])
        self.assertFalse(valid)
        self.assertEqual(calls, 2)


if __name__ == '__main__':
    unittest.main()
