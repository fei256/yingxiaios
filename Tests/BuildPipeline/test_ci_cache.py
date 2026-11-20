"""Check cache invalidation and timestamp reuse without requiring a Mac."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[2] / 'Scripts'
sys.path.insert(0, str(SCRIPTS))
import build_resources

spec = importlib.util.spec_from_file_location('ci_cache', SCRIPTS / 'ci-build-cache.py')
ci_cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_cache)


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.modes = {}
        self.state = self.root / 'build/source-timestamps.json'
        patch = mock.patch.object(ci_cache, 'tracked_modes', return_value=self.modes)
        patch.start()
        self.addCleanup(patch.stop)

    def file(self, name, data=b'input', mode='100644'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.modes[name] = mode
        return path

    def fingerprint(self):
        return ci_cache.fingerprint(self.root, self.modes, ci_cache.NATIVE_INPUTS)[0]

    def test_generated_bytecode_and_dependency_outputs_do_not_change_key(self):
        self.file('Scripts/recipe.py')
        self.file('Vendor/FFmpeg/patch.diff')
        expected = self.fingerprint()
        for name in ['Scripts/__pycache__/recipe.cpython-313.pyc',
                     'Vendor/FFmpeg/FFmpeg.xcframework/ios-arm64/libFFmpeg.a']:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'generated on this runner')
        self.assertEqual(self.fingerprint(), expected)

    def test_tracked_recipe_content_and_mode_changes_invalidate_key(self):
        path = self.file('Scripts/recipe.py')
        original = self.fingerprint()
        path.write_bytes(b'new recipe')
        changed = self.fingerprint()
        self.assertNotEqual(changed, original)
        self.modes['Scripts/recipe.py'] = '100755'
        self.assertNotEqual(self.fingerprint(), changed)

    def test_ui_changes_do_not_invalidate_native_dependencies(self):
        self.file('Scripts/recipe.py')
        path = self.file('App/Screen.swift')
        expected = self.fingerprint()
        path.write_bytes(b'updated screen')
        self.assertEqual(self.fingerprint(), expected)

    def test_link_target_is_hashed_without_following_generated_binary(self):
        path = self.file('Vendor/FFmpeg/FFmpeg.xcframework', b'../../build/FFmpeg', mode='120000')
        expected = self.fingerprint()
        output = self.root / 'build/FFmpeg/libFFmpeg.a'
        output.parent.mkdir(parents=True)
        output.write_bytes(b'new generated library')
        self.assertEqual(self.fingerprint(), expected)
        path.write_bytes(b'../../build/other')
        self.assertNotEqual(self.fingerprint(), expected)

    def test_missing_tracked_recipe_cannot_reuse_a_cache(self):
        self.file('Scripts/recipe.py').unlink()
        with self.assertRaisesRegex(RuntimeError, 'missing'):
            self.fingerprint()

    def test_unchanged_source_recovers_timestamp_but_changed_source_does_not(self):
        unchanged = self.file('App/Unchanged.swift')
        changed = self.file('App/Changed.swift')
        earlier = 1700000000 * 10 ** 9
        later = earlier + 10 ** 9
        for path in [unchanged, changed]:
            os.utime(path, ns=(earlier, earlier))
        ci_cache.save_timestamps(self.root, self.state)
        changed.write_bytes(b'new code')
        for path in [unchanged, changed]:
            os.utime(path, ns=(later, later))
        report = ci_cache.restore_timestamps(self.root, self.state)
        self.assertEqual(report, {'status': 'restored', 'restored': 1, 'changed': 1})
        self.assertEqual(unchanged.stat().st_mtime_ns, earlier)
        self.assertEqual(changed.stat().st_mtime_ns, later)

    def test_untracked_paths_in_timestamp_state_are_never_modified(self):
        self.file('App/Screen.swift')
        outside = self.root / 'untracked.txt'
        outside.write_text('keep')
        previous = outside.stat().st_mtime_ns
        ci_cache.save_timestamps(self.root, self.state)
        state = json.loads(self.state.read_text())
        state['files']['untracked.txt'] = {'sha256': ci_cache.sha256(outside), 'mtime_ns': 0}
        state['files']['../outside.txt'] = {'sha256': 'unused', 'mtime_ns': 0}
        self.state.write_text(json.dumps(state))
        ci_cache.restore_timestamps(self.root, self.state)
        self.assertEqual(outside.stat().st_mtime_ns, previous)

    def test_missing_and_invalid_timestamp_states_fall_back_to_normal_build(self):
        self.assertEqual(ci_cache.restore_timestamps(self.root, self.state)['status'], 'no-cache')
        self.state.parent.mkdir(parents=True)
        for data in ['invalid JSON', 'null', '{"format":1,"files":[]}']:
            with self.subTest(data=data):
                self.state.write_text(data)
                self.assertEqual(ci_cache.restore_timestamps(self.root, self.state)['status'], 'invalid-cache')


class BuildResourcesTests(unittest.TestCase):
    def test_memory_limit_applies_even_when_many_cpu_cores_are_available(self):
        with mock.patch.object(build_resources, 'sysctl_number', side_effect=[12, 7 * 1024 ** 3]):
            self.assertEqual(build_resources.build_resources()['jobs'], 1)

    def test_ci_uses_same_default_as_local_build_and_preserves_explicit_override(self):
        with mock.patch.object(build_resources, 'sysctl_number', side_effect=[4, 14 * 1024 ** 3] * 2):
            self.assertEqual(build_resources.build_resources()['jobs'], 3)
            self.assertEqual(build_resources.build_resources(2)['jobs'], 2)
