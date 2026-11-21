"""Check installable ZIP names, executable modes, and link payloads."""
from pathlib import Path
import os
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Scripts'))
from ipa_archive import write_payload_zip


class IPAArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.payload = self.root / 'Payload'
        self.app = self.payload / 'Fixture.app'
        self.app.mkdir(parents=True)
        self.output = self.root / 'fixture.ipa'

    def test_utf8_name_has_unambiguous_zip_flag_and_exact_bytes(self):
        path = self.app / '模板.js'
        data = 'export const 模板 = "原始内容";\n'.encode('utf-8')
        path.write_bytes(data)
        write_payload_zip(self.payload, self.output)
        with zipfile.ZipFile(self.output) as archive:
            name = 'Payload/Fixture.app/模板.js'
            self.assertEqual(archive.read(name), data)
            self.assertTrue(archive.getinfo(name).flag_bits & 0x800)
            self.assertIsNone(archive.testzip())
            self.assertTrue(all(value.startswith('Payload/') for value in archive.namelist()))

    def test_existing_output_is_never_replaced(self):
        self.output.write_bytes(b'previous verified delivery')
        with self.assertRaises(FileExistsError):
            write_payload_zip(self.payload, self.output)
        self.assertEqual(self.output.read_bytes(), b'previous verified delivery')

    @unittest.skipUnless(os.name == 'posix', 'Unix executable modes are exercised on the macOS builder')
    def test_executable_mode_is_preserved(self):
        executable = self.app / 'Fixture'
        executable.write_bytes(b'fixture executable')
        executable.chmod(0o755)
        write_payload_zip(self.payload, self.output)
        with zipfile.ZipFile(self.output) as archive:
            metadata = archive.getinfo('Payload/Fixture.app/Fixture')
            self.assertEqual(metadata.external_attr >> 16 & 0o777, 0o755)
            self.assertEqual(metadata.create_system, 3)

    def test_symlink_is_stored_without_copying_its_target(self):
        target = self.app / 'script.js'
        target.write_bytes(b'target content')
        link = self.app / 'entry.js'
        try:
            link.symlink_to('script.js')
        except OSError as error:
            self.skipTest('Symlink creation unavailable: ' + str(error))
        write_payload_zip(self.payload, self.output)
        with zipfile.ZipFile(self.output) as archive:
            metadata = archive.getinfo('Payload/Fixture.app/entry.js')
            self.assertEqual(stat.S_IFMT(metadata.external_attr >> 16), stat.S_IFLNK)
            self.assertEqual(archive.read(metadata.filename), b'script.js')
            self.assertEqual(archive.read('Payload/Fixture.app/script.js'), b'target content')


if __name__ == '__main__':
    unittest.main()
