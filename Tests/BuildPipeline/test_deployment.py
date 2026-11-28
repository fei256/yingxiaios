from pathlib import Path
import struct
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
from native_deployment import ARM64, inspect_bytes, inspect_file, version_tuple


def image(minimum=(16, 1), platform=2, cpu=ARM64, legacy=False):
    value = minimum[0] << 16 | minimum[1] << 8
    command = struct.pack("<IIII", 0x25, 16, value, 0) if legacy else struct.pack("<IIIIII", 0x32, 24, platform, value, 0, 0)
    return struct.pack("<IIIIIIII", 0xFEEDFACF, cpu, 0, 1, 1, len(command), 0, 0) + command


def archive(members):
    data = bytearray(b"!<arch>\n")
    for name, body in members:
        header = f"{name:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(body):<10}`\n".encode("ascii")
        data += header + body + (b"\n" if len(body) % 2 else b"")
    return bytes(data)


class NativeDeploymentTests(unittest.TestCase):
    def test_aether_metadata_follows_verified_binary_minimum(self):
        from aether_frameworks import LIBRARIES, embed

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout, frameworks = root / "checkout", root / "app/Frameworks"
            for name in LIBRARIES:
                original = checkout / "Sources" / (name + ".xcframework") / "ios-arm64" / (name + ".framework")
                original.mkdir(parents=True)
                (original / name).write_bytes(image((16, 0)))
                (original / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name, "MinimumOSVersion": "26.0"}))
            embed(frameworks, checkout)
            embed(frameworks, checkout)
            for name in LIBRARIES:
                bundle = frameworks / (name + ".framework")
                self.assertEqual(plistlib.loads((bundle / "Info.plist").read_bytes())["MinimumOSVersion"], "16.1")
                self.assertEqual((bundle / name).read_bytes(), image((16, 0)))
                self.assertTrue((bundle / "PrivacyInfo.xcprivacy").is_file())

            name = LIBRARIES[0]
            bundle = frameworks / (name + ".framework")
            original_info = plistlib.dumps({"CFBundleExecutable": name, "MinimumOSVersion": "26.0"})
            (bundle / "Info.plist").write_bytes(original_info)
            for incompatible in [image((16, 2)), image(platform=7)]:
                (bundle / name).write_bytes(incompatible)
                with self.assertRaises(ValueError):
                    embed(frameworks, checkout)
                self.assertEqual((bundle / "Info.plist").read_bytes(), original_info)

    def test_every_duplicate_archive_member_is_checked(self):
        data = archive([("same.o/", image()), ("same.o/", image((16, 2)))])
        records = inspect_bytes(data)
        self.assertEqual([row["minimum_os"] for row in records], ["16.1", "16.2"])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "library.a"; path.write_bytes(data)
            report = inspect_file(path)
            self.assertEqual(report["code_members"], 2)
            self.assertEqual(len(report["errors"]), 1)

    def test_bsd_extended_names_and_symbol_tables_are_handled(self):
        name = b"a-very-long-object-name.o\0"
        data = archive([("__.SYMDEF/", b"symbols"), ("#1/" + str(len(name)), name + image())])
        self.assertEqual(len(inspect_bytes(data)), 1)

    def test_simulator_or_non_arm64_object_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "simulator.o"; path.write_bytes(image(platform=7))
            self.assertTrue(inspect_file(path)["errors"])
            path.write_bytes(image(cpu=0x01000007))
            self.assertTrue(inspect_file(path)["errors"])

    def test_universal_static_archive_is_inspected_recursively(self):
        body = archive([("model.o/", image((15, 1)))])
        header = struct.pack(">II", 0xCAFEBABE, 1) + struct.pack(">IIIII", ARM64, 0, 28, len(body), 0)
        records = inspect_bytes(header + body)
        self.assertEqual(records[0]["minimum_os"], "15.1")

    def test_legacy_minimum_commands_and_patch_versions_compare_correctly(self):
        self.assertEqual(inspect_bytes(image(legacy=True))[0]["platform"], "IOS")
        self.assertEqual(version_tuple("16.1"), version_tuple("16.1.0"))

    def test_truncation_and_unidentified_code_never_count_as_verified(self):
        with self.assertRaises(ValueError): inspect_bytes(archive([("object.o/", b"unknown")]))
        with self.assertRaises(ValueError): inspect_bytes(archive([("object.o/", image())])[:-1])


if __name__ == "__main__":
    unittest.main()
