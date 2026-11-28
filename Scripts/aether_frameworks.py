"""Embed FFmpegBuild's dynamic Apple libraries and align their bundle metadata with the host."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

from native_deployment import ARM64, inspect_bytes, version_tuple

ROOT = Path(__file__).resolve().parent.parent
LIBRARIES = tuple('AetherLib' + name for name in
                  ('avcodec', 'avformat', 'avutil', 'avfilter', 'swresample', 'swscale', 'dav1d', 'zimg', 'zvbi'))


def write_bundle_file(destination, data, mode=0o644):
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as pending:
        temp = Path(pending.name)
    try:
        temp.write_bytes(data)
        temp.chmod(mode)
        os.replace(temp, destination)
    finally:
        temp.unlink(missing_ok=True)


def embed(frameworks, checkout, platform='iphoneos', minimum='16.1', sign=None):
    slice_name, expected = {
        'iphoneos': ('ios-arm64', 'IOS'),
        'iphonesimulator': ('ios-arm64_x86_64-simulator', 'IOSSIMULATOR'),
    }[platform]
    manifest = (ROOT / 'Config/Aether/PrivacyInfo.xcprivacy').read_bytes()
    frameworks.mkdir(parents=True, exist_ok=True)
    for name in LIBRARIES:
        bundle = frameworks / (name + '.framework')
        original = checkout / 'Sources' / (name + '.xcframework') / slice_name / bundle.name
        binary = bundle / name
        # Xcode may embed transitive package frameworks itself. When only the bridge
        # received the package, copy its runtime payload from the resolved checkout.
        binary_data = (binary if binary.is_file() else original / name).read_bytes()
        records = inspect_bytes(binary_data, name=name)
        if any(r['platform'] != expected or version_tuple(r['minimum_os']) > version_tuple(minimum)
               or (platform == 'iphoneos' and r['cpu'] != ARM64) for r in records):
            raise ValueError(f'{name} cannot run on {expected} {minimum}: {records}')
        info_path = bundle / 'Info.plist'
        info = plistlib.loads((info_path if info_path.is_file() else original / 'Info.plist').read_bytes())
        if info['CFBundleExecutable'] != name:
            raise ValueError(f'{name} executable does not match its framework')
        bundle.mkdir(exist_ok=True)
        if not binary.is_file():
            write_bundle_file(binary, binary_data, 0o755)
        if not info_path.is_file() or info.get('MinimumOSVersion') != minimum:
            info['MinimumOSVersion'] = minimum
            write_bundle_file(info_path, plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        privacy = bundle / 'PrivacyInfo.xcprivacy'
        if not privacy.exists():
            write_bundle_file(privacy, manifest)
        if sign:
            subprocess.run(['codesign', '--force', '--sign', sign, '--timestamp=none', str(bundle)], check=True)


if __name__ == '__main__':
    products = Path(os.environ['TARGET_BUILD_DIR'])
    derived = Path(os.environ['BUILD_DIR']).parents[1]
    checkouts = [ROOT / 'build/SourcePackages/checkouts/FFmpegBuild', derived / 'SourcePackages/checkouts/FFmpegBuild']
    checkout = next((path for path in checkouts if path.is_dir()), checkouts[0])
    embed(products / os.environ['FRAMEWORKS_FOLDER_PATH'], checkout, os.environ['PLATFORM_NAME'],
          os.environ['IPHONEOS_DEPLOYMENT_TARGET'],
          os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') if os.environ.get('CODE_SIGNING_ALLOWED') != 'NO' else None)
