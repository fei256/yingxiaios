"""Inspect every Mach-O member of the actual iOS link inputs without executing it."""
import argparse
from collections import Counter
import hashlib
import json
import mmap
from pathlib import Path
import plistlib
import struct

from build_validation import require_validation_enabled

MAXIMUM_IOS = "16.1"
ARM64 = 0x0100000C
PLATFORMS = {1: "MACOS", 2: "IOS", 3: "TVOS", 4: "WATCHOS", 7: "IOSSIMULATOR"}
MACHO = {b"\xcf\xfa\xed\xfe": ("<", 32), b"\xfe\xed\xfa\xcf": (">", 32),
         b"\xce\xfa\xed\xfe": ("<", 28), b"\xfe\xed\xfa\xce": (">", 28)}
FAT = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
       b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}


def version_tuple(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def packed_version(value):
    parts = [value >> 16, (value >> 8) & 255, value & 255]
    return ".".join(str(part) for part in parts[:3 if parts[2] else 2])


def inspect_bytes(data, start=0, size=None, name="image"):
    size = len(data) - start if size is None else size
    end = start + size
    if size < 4 or start < 0 or end > len(data):
        raise ValueError("Truncated native input: " + name)
    magic = data[start:start + 4]
    if data[start:start + 8] == b"!<arch>\n":
        records, cursor = [], start + 8
        while cursor < end:
            if cursor + 60 > end or data[cursor + 58:cursor + 60] != b"`\n":
                raise ValueError("Invalid archive header: " + name)
            header = data[cursor:cursor + 60]
            length = int(header[48:58].strip())
            body = cursor + 60
            if length < 0 or body + length > end:
                raise ValueError("Truncated archive member: " + name)
            member = header[:16].decode("ascii").strip()
            payload, payload_size = body, length
            if member.startswith("#1/"):
                name_length = int(member[3:])
                if name_length > length:
                    raise ValueError("Invalid extended archive member: " + name)
                member = data[body:body + name_length].decode("utf-8").rstrip("\0")
                payload += name_length; payload_size -= name_length
            if member not in ("/", "//", "/SYM64/") and not member.startswith("__.SYMDEF"):
                records += inspect_bytes(data, payload, payload_size, name + "(" + member.rstrip("/") + ")")
            cursor = body + length + length % 2
        if not records:
            raise ValueError("Archive contains no inspectable code: " + name)
        return records
    if magic in FAT:
        endian, wide = FAT[magic]
        count = struct.unpack_from(endian + "I", data, start + 4)[0]
        stride = 32 if wide else 20
        if not 0 < count <= 64 or start + 8 + count * stride > end:
            raise ValueError("Invalid universal native input: " + name)
        records = []
        for index in range(count):
            fields = struct.unpack_from(endian + ("IIQQII" if wide else "IIIII"), data, start + 8 + index * stride)
            offset, length = fields[2:4]
            if offset < 8 + count * stride or offset + length > size:
                raise ValueError("Invalid universal slice: " + name)
            records += inspect_bytes(data, start + offset, length, name + f"[slice {index}]")
        return records
    if magic not in MACHO:
        raise ValueError("Unrecognized code member; deployment remains unverified: " + name)
    endian, header_size = MACHO[magic]
    if size < header_size:
        raise ValueError("Truncated Mach-O header: " + name)
    cpu, _, _, count, command_bytes = struct.unpack_from(endian + "IIIII", data, start + 4)
    cursor = start + header_size
    command_end = cursor + command_bytes
    if count > 65536 or command_end > end:
        raise ValueError("Invalid Mach-O commands: " + name)
    minimum, platform = None, None
    for _ in range(count):
        if cursor + 8 > command_end:
            raise ValueError("Truncated Mach-O command: " + name)
        command, length = struct.unpack_from(endian + "II", data, cursor)
        if length < 8 or cursor + length > command_end:
            raise ValueError("Invalid Mach-O command length: " + name)
        if command == 0x32 and length >= 24:
            platform_code, value = struct.unpack_from(endian + "II", data, cursor + 8)
            platform = PLATFORMS.get(platform_code, str(platform_code)); minimum = packed_version(value)
        elif command in (0x24, 0x25, 0x2F, 0x30) and length >= 16:
            platform = {0x24: "MACOS", 0x25: "IOS", 0x2F: "TVOS", 0x30: "WATCHOS"}[command]
            minimum = packed_version(struct.unpack_from(endian + "I", data, cursor + 8)[0])
        cursor += length
    if minimum is None:
        raise ValueError("Native deployment command is missing: " + name)
    return [{"member": name, "cpu": cpu, "platform": platform, "minimum_os": minimum}]


def inspect_file(path, maximum=MAXIMUM_IOS):
    path = Path(path)
    with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        records = inspect_bytes(data, name=path.name)
        digest = hashlib.sha256(data).hexdigest()
    errors = []
    for record in records:
        if record["cpu"] != ARM64 or record["platform"] != "IOS":
            errors.append(record["member"] + ": not arm64 iPhoneOS")
        if version_tuple(record["minimum_os"]) > version_tuple(maximum):
            errors.append(record["member"] + ": requires iOS " + record["minimum_os"])
    return {"path": str(path), "sha256": digest, "bytes": path.stat().st_size,
            "inspection_scope": "all archive members and universal slices", "code_members": len(records),
            "minimum_os_counts": dict(Counter(record["minimum_os"] for record in records)), "errors": errors}


def xcframework_device_inputs(path):
    path = Path(path)
    metadata = plistlib.loads((path / "Info.plist").read_bytes())
    files = []
    for library in metadata["AvailableLibraries"]:
        if library["SupportedPlatform"] != "ios" or library.get("SupportedPlatformVariant"):
            continue
        if "arm64" not in library["SupportedArchitectures"]:
            continue
        target = path / library["LibraryIdentifier"] / library["LibraryPath"]
        if target.suffix == ".framework":
            info = plistlib.loads((target / "Info.plist").read_bytes())
            target = target / info["CFBundleExecutable"]
        files.append(target)
    if not files:
        raise ValueError("No arm64 iOS device slice: " + str(path))
    return files


def inspect_link_inputs(root, maximum=MAXIMUM_IOS):
    root = Path(root)
    libraries, errors, files = [], [], []
    frameworks = ["build/FFmpeg/FFmpeg.xcframework", "Vendor/DiscNative/DiscNative.xcframework",
                  "Vendor/NativeASR/TVASR.xcframework", "build/RuntimeDependencies/NodeMobile/NodeMobile.xcframework"]
    for name in frameworks:
        try:
            files += xcframework_device_inputs(root / name)
        except (OSError, ValueError, KeyError) as error:
            errors.append(str(error))
    for framework in (root / "build/ApplePython/iphoneos/Frameworks").glob("*.framework"):
        try:
            info = plistlib.loads((framework / "Info.plist").read_bytes())
            files.append(framework / info["CFBundleExecutable"])
        except (OSError, ValueError, KeyError) as error:
            errors.append(str(error))
    if not any("Python.framework" in str(path) for path in files):
        errors.append("Python device runtime was not inspected")
    for path in files:
        try:
            result = inspect_file(path, maximum)
            result["path"] = path.relative_to(root).as_posix()
            errors += result["errors"]; libraries.append(result)
        except (OSError, ValueError, struct.error) as error:
            errors.append(str(error))
    return {"maximum_ios": maximum, "libraries": libraries, "code_members": sum(item["code_members"] for item in libraries), "errors": errors}


if __name__ == "__main__":
    require_validation_enabled()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = inspect_link_inputs(args.root)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Inspected {len(report['libraries'])} native inputs and {report['code_members']} code members.")
    if report["errors"]:
        raise SystemExit("\n".join(report["errors"][:40]))
