"""Regression cases for failures seen or found during the GitHub build audit."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[2] / 'Scripts'
sys.path.insert(0, str(SCRIPTS))
import build_validation
import python_runtime_cache as python_cache
import source_layout
import source_snapshot
import verified_download


class TemporaryProject(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def file(self, name, data=b'input'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def symlink(self, link, target):
        link.parent.mkdir(parents=True, exist_ok=True)
        try:
            link.symlink_to(target, target_is_directory=True)
        except OSError as error:
            self.skipTest('This host cannot create symlinks: ' + str(error))


class SourceLayoutTests(TemporaryProject):
    def setUp(self):
        super().setUp()
        self.modes = {name: '120000' for name in source_layout.SOURCE_LINKS}
        for name, target in source_layout.SOURCE_LINKS.items():
            self.file(name, target.encode())
        self.file('Package.swift', b'// swift-tools-version: 6.0\nimport PackageDescription\n')
        self.script = self.file('Scripts/build.sh', b'#!/bin/bash\nset -euo pipefail\n')
        self.modes['Scripts/build.sh'] = '100755'
        self.patch = mock.patch.object(source_layout, 'git_modes', return_value=self.modes)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def test_windows_git_symlink_placeholders_are_accepted(self):
        self.assertEqual(source_layout.check_source_layout(self.root, windows=True)['errors'], [])

    def test_flattened_alias_is_rejected_for_macos(self):
        errors = source_layout.check_source_layout(self.root, windows=False)['errors']
        self.assertTrue(any('source link was flattened' in error for error in errors))

    def test_wrong_git_link_mode_is_rejected_even_on_windows(self):
        self.modes['Packages/TVCore/Package.swift'] = '100644'
        errors = source_layout.check_source_layout(self.root, windows=True)['errors']
        self.assertTrue(any('120000 symlink' in error for error in errors))

    def test_changed_placeholder_target_is_rejected(self):
        self.file('Packages/TVCore/Package.swift', b'../../wrong.swift')
        self.assertTrue(source_layout.check_source_layout(self.root, windows=True)['errors'])

    def test_staged_link_target_cannot_differ_from_working_placeholder(self):
        (self.root / '.git').mkdir()
        with mock.patch.object(source_layout.subprocess, 'check_output', return_value=b'../../wrong'):
            errors = source_layout.check_source_layout(self.root, windows=True)['errors']
        self.assertTrue(any('staged Git link target differs' in error for error in errors))

    def test_script_git_executable_mode_is_required(self):
        self.modes['Scripts/build.sh'] = '100644'
        errors = source_layout.check_source_layout(self.root, windows=True)['errors']
        self.assertTrue(any('100755' in error for error in errors))

    def test_shell_crlf_is_rejected(self):
        self.script.write_bytes(b'#!/bin/bash\r\nexit 0\r\n')
        errors = source_layout.check_source_layout(self.root, windows=True)['errors']
        self.assertTrue(any('LF line endings' in error for error in errors))

    def test_obsolete_swift_tools_header_is_rejected(self):
        self.file('Package.swift', b'// swift-tools-version: 3.1\n')
        errors = source_layout.check_source_layout(self.root, windows=True)['errors']
        self.assertTrue(any('swift-tools-version: 6.0' in error for error in errors))


class SnapshotTests(TemporaryProject):
    def test_alias_target_change_is_detected_without_reading_alias_children(self):
        self.file('Sources/input.swift', b'identical')
        self.file('Other/input.swift', b'identical')
        link = self.root / 'Packages/TVCore/Sources'
        self.symlink(link, '../../Sources')
        before = source_snapshot.source_checksums(self.root)
        link.unlink()
        self.symlink(link, '../../Other')
        after = source_snapshot.source_checksums(self.root)
        self.assertIn('Packages/TVCore/Sources', source_snapshot.changed_inputs(before, after))
        self.assertNotIn('Packages/TVCore/Sources/input.swift', before)

    def test_executable_mode_change_is_detected(self):
        script = self.file('Scripts/build.sh', b'#!/bin/bash\nexit 0\n')
        if os.name == 'nt':
            with mock.patch.object(source_snapshot, 'git_modes', return_value={'Scripts/build.sh': '100755'}):
                before = source_snapshot.source_checksums(self.root)
            with mock.patch.object(source_snapshot, 'git_modes', return_value={'Scripts/build.sh': '100644'}):
                after = source_snapshot.source_checksums(self.root)
        else:
            script.chmod(0o755)
            before = source_snapshot.source_checksums(self.root)
            script.chmod(0o644)
            after = source_snapshot.source_checksums(self.root)
        self.assertIn('@mode/Scripts/build.sh', source_snapshot.changed_inputs(before, after))

    def test_added_native_binary_is_detected(self):
        self.file('Vendor/DiscNative/DiscNative.xcframework/ios-arm64/lib.a')
        before = source_snapshot.native_checksums(self.root)
        self.file('Vendor/DiscNative/DiscNative.xcframework/ios-arm64/unexpected.a')
        after = source_snapshot.native_checksums(self.root)
        self.assertEqual(source_snapshot.changed_inputs(before, after),
                         ['Vendor/DiscNative/DiscNative.xcframework/ios-arm64/unexpected.a'])

    def test_deleted_source_is_detected(self):
        path = self.file('Sources/file.swift')
        before = source_snapshot.source_checksums(self.root)
        path.unlink()
        self.assertEqual(source_snapshot.changed_inputs(before, source_snapshot.source_checksums(self.root)),
                         ['Sources/file.swift'])


class DownloadTests(TemporaryProject):
    def setUp(self):
        super().setUp()
        self.target = self.root / 'archive.tar.gz'
        self.data = b'complete pinned archive'
        self.checksum = hashlib.sha256(self.data).hexdigest()

    def download(self, command, **kwargs):
        Path(command[command.index('--output') + 1]).write_bytes(self.data)
        self.assertIn('--retry-all-errors', command)
        return subprocess.CompletedProcess(command, 0)

    def fetch(self):
        return verified_download.download_verified('https://example.invalid/input', self.checksum, self.target)

    def test_valid_cache_needs_no_network(self):
        self.target.write_bytes(self.data)
        with mock.patch.object(verified_download.subprocess, 'run') as download:
            self.fetch()
            download.assert_not_called()

    def test_truncated_cached_archive_is_refetched(self):
        self.target.write_bytes(b'partial')
        with mock.patch.object(verified_download.subprocess, 'run', side_effect=self.download) as download:
            self.fetch()
        self.assertEqual(download.call_count, 1)
        self.assertEqual(self.target.read_bytes(), self.data)

    def test_interrupted_download_is_not_published_and_can_be_retried(self):
        def interrupted(command, **kwargs):
            Path(command[command.index('--output') + 1]).write_bytes(b'partial')
            raise subprocess.CalledProcessError(7, command)
        with mock.patch.object(verified_download.subprocess, 'run', side_effect=interrupted):
            with self.assertRaises(subprocess.CalledProcessError):
                self.fetch()
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.root.iterdir()), [])
        with mock.patch.object(verified_download.subprocess, 'run', side_effect=self.download):
            self.fetch()
        self.assertEqual(self.target.read_bytes(), self.data)

    def test_hash_mismatch_never_replaces_the_target(self):
        self.target.write_bytes(b'previous incomplete cache')
        def incorrect(command, **kwargs):
            Path(command[command.index('--output') + 1]).write_bytes(b'wrong content')
            return subprocess.CompletedProcess(command, 0)
        with mock.patch.object(verified_download.subprocess, 'run', side_effect=incorrect):
            with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
                self.fetch()
        self.assertEqual(self.target.read_bytes(), b'previous incomplete cache')
        self.assertEqual(list(self.root.iterdir()), [self.target])


class PythonCacheTests(TemporaryProject):
    def setUp(self):
        super().setUp()
        for name in python_cache.RECIPE_INPUTS:
            self.file(name)
        self.toolchain = {'xcode': '16.1', 'sdk': '18.1', 'host': '3.14'}
        self.fingerprint = python_cache.recipe_fingerprint(self.root, self.toolchain)
        self.runtime = self.root / 'build/ApplePython/iphoneos'
        self.binary = self.file('build/ApplePython/iphoneos/Frameworks/Python.framework/Python')
        self.file('build/ApplePython/iphoneos/python/lib/stdlib.py')

    def receipt(self):
        data = {'format': 1, 'recipe': self.fingerprint, 'outputs': python_cache.runtime_checksums(self.runtime)}
        (self.runtime / '.prepared.json').write_text(json.dumps(data))

    def test_valid_runtime_receipt_is_accepted(self):
        self.receipt()
        self.assertTrue(python_cache.cache_ready(self.runtime, self.fingerprint))

    def test_corrupted_runtime_and_added_file_invalidate_receipt(self):
        self.receipt()
        self.binary.write_bytes(b'corrupt')
        self.assertFalse(python_cache.cache_ready(self.runtime, self.fingerprint))
        self.receipt()
        self.file('build/ApplePython/iphoneos/python/lib/unexpected.py')
        self.assertFalse(python_cache.cache_ready(self.runtime, self.fingerprint))

    def test_malformed_or_legacy_receipt_is_not_reused(self):
        (self.runtime / '.prepared').write_text(self.fingerprint)
        self.assertFalse(python_cache.cache_ready(self.runtime, self.fingerprint))
        (self.runtime / '.prepared.json').write_text('[]')
        self.assertFalse(python_cache.cache_ready(self.runtime, self.fingerprint))

    def test_recipe_change_invalidates_wheels_even_at_same_package_version(self):
        self.file('Scripts/build-apple-python-wheels.sh', b'changed compiler recipe')
        changed = python_cache.recipe_fingerprint(self.root, self.toolchain)
        self.assertNotEqual(self.fingerprint, changed)
        old = python_cache.reset_recipe_work(self.root, self.fingerprint)
        (old / 'same-version.whl').write_bytes(b'old wheel')
        new = python_cache.reset_recipe_work(self.root, changed)
        self.assertNotEqual(old, new)
        self.assertFalse((new / 'same-version.whl').exists())
        self.assertTrue((old / 'same-version.whl').exists())

    def test_toolchain_change_invalidates_runtime(self):
        self.assertNotEqual(self.fingerprint, python_cache.recipe_fingerprint(self.root, {'xcode': '16.2'}))

    def test_recipe_reset_preserves_other_caches_and_rejects_path_escape(self):
        preserved = self.file('build/apple-python/unrelated.tar.gz')
        work = python_cache.reset_recipe_work(self.root, self.fingerprint)
        (work / 'partial.whl').write_bytes(b'partial')
        python_cache.reset_recipe_work(self.root, self.fingerprint)
        self.assertTrue(preserved.is_file())
        self.assertEqual(list(work.iterdir()), [])
        with self.assertRaises(ValueError):
            python_cache.reset_recipe_work(self.root, '../../outside')

    def test_preparation_publishes_receipt_only_after_success_then_reuses_it(self):
        with mock.patch.dict(os.environ, {'HOST_PYTHON': 'host-python'}), \
             mock.patch.object(python_cache.subprocess, 'check_output', return_value='fixed toolchain'), \
             mock.patch.object(python_cache.subprocess, 'run') as build, contextlib.redirect_stdout(io.StringIO()):
            build.side_effect = subprocess.CalledProcessError(1, ['build'])
            with self.assertRaises(subprocess.CalledProcessError):
                python_cache.prepare_python_runtime(self.root)
            self.assertFalse((self.runtime / '.prepared.json').exists())
            build.side_effect = None
            python_cache.prepare_python_runtime(self.root)
            self.assertTrue((self.runtime / '.prepared.json').exists())
            python_cache.prepare_python_runtime(self.root)
            self.assertEqual(build.call_count, 2)


class ValidationTests(TemporaryProject):
    def test_optimized_python_cannot_bypass_critical_entrypoints(self):
        names = ['preflight-ios-source.py', 'prepare-ios-dependencies.py', 'prepare-ios-platform.py',
                 'build-ios-ipa.py', 'package-ios-ipa.py', 'validate-ios-ipa.py', 'validate-ios-player.py']
        for name in names:
            with self.subTest(name=name):
                result = subprocess.run([sys.executable, '-O', str(SCRIPTS / name)],
                                        capture_output=True, text=True,
                                        env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Required build checks cannot run with Python optimization', result.stderr)

    def test_first_compiler_error_is_visible_even_if_archive_tail_has_only_notes(self):
        error = 'App/File.swift:10:8: error: main actor-isolated completion called from a nonisolated context'
        log = ('compiler arguments ' * 10000) + '\n' + error + '\n' + ('note: Disabling previews\n' * 2000) + '** ARCHIVE FAILED **\n'
        excerpt = build_validation.archive_failure_excerpt(log)
        self.assertIn(error, excerpt)
        self.assertIn('** ARCHIVE FAILED **', excerpt)
        self.assertLessEqual(len(excerpt), 24100)

    def test_simulator_macho_is_rejected_even_with_arm64_and_ios16_minimum(self):
        app = self.root / 'Test.app'
        executable = self.file('Test.app/Test', bytes.fromhex('cffaedfe') + b'\0' * 20)
        self.file('Test.app/bad.dylib', bytes.fromhex('cffaedfe') + b'\0' * 20)
        self.file('Runtime/PythonHost/requirements.txt', b'')
        info = {'CFBundleExecutable': executable.name, 'MinimumOSVersion': '16.2',
                'UIDeviceFamily': [1, 2], 'LSSupportsOpeningDocumentsInPlace': True}
        self.file('Test.app/Info.plist', plistlib.dumps(info))
        output = self.root / 'reports'
        def command(arguments, **kwargs):
            if arguments[0] == 'xcrun':
                platform = 'IOSSIMULATOR' if arguments[-1].endswith('bad.dylib') else 'IOS'
                return 'platform ' + platform + '\nminos 16.2\n'
            if arguments[0] == 'lipo':
                return 'arm64\n'
            return ''
        with mock.patch.object(Path, 'cwd', return_value=self.root), \
             mock.patch.object(subprocess, 'check_output', side_effect=command), \
             mock.patch.object(sys, 'argv', ['validate-ios-ipa.py', str(app), str(output)]), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit):
                runpy.run_path(str(SCRIPTS / 'validate-ios-ipa.py'), run_name='__main__')
        report = json.loads((output / 'ipa-validation.json').read_text())
        self.assertTrue(any('bad.dylib: platform' in error for error in report['errors']))

    def test_missing_dependency_link_is_restored_and_real_directory_is_preserved(self):
        target = self.root / 'built-framework'
        target.mkdir()
        link = self.root / 'Vendor/link'
        self.symlink(link, '../missing')
        build_validation.ensure_directory_link(link, target)
        self.assertEqual(link.resolve(), target.resolve())
        real = self.root / 'Vendor/real'
        real.mkdir()
        with self.assertRaisesRegex(RuntimeError, 'Refusing to replace'):
            build_validation.ensure_directory_link(real, target)
        self.assertTrue(real.is_dir())


if __name__ == '__main__':
    unittest.main()
