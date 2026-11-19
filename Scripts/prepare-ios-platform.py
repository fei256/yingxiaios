#!/usr/bin/env python3
"""Install and verify the iOS runtime required by the selected device SDK."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time

from build_validation import require_validation_enabled, sha256


def installed(version):
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
    return any(runtime.get('version') == version and runtime.get('isAvailable')
               and 'iOS' in runtime.get('name', '') for runtime in runtimes)


def verify_dmg(archive):
    result = subprocess.run(['hdiutil', 'verify', str(archive)], text=True, capture_output=True,
                            env=dict(os.environ, LC_ALL='C'))
    message = (result.stdout or '') + (result.stderr or '')
    if message:
        print(message.rstrip(), flush=True)
    if result.returncode == 0:
        return True
    # Xcode exports valid runtime DMGs without an embedded UDIF checksum. A
    # checksum mismatch still fails; only this explicit absence permits the
    # readable-image check, followed by Xcode import and runtime verification.
    if not re.search(r'has no checksum\.\s*$', message):
        return False
    info = subprocess.run(['hdiutil', 'imageinfo', '-plist', str(archive)], text=True, capture_output=True)
    if info.returncode != 0:
        return False
    try:
        readable = isinstance(plistlib.loads(info.stdout.encode()), dict)
    except (ValueError, plistlib.InvalidFileException):
        return False
    if readable:
        print('Platform DMG has no embedded checksum; image metadata is readable. '
              'Xcode import, runtime version and the cache SHA-256 are checked separately.', flush=True)
    return readable


def cached_archive(folder, version):
    archives = list(folder.rglob('*.dmg'))
    if len(archives) != 1:
        return None
    archive = archives[0]
    if archive.is_symlink() or not archive.resolve().is_relative_to(folder.resolve()):
        return None
    receipt = folder / 'platform-receipt.json'
    if receipt.is_file():
        try:
            previous = json.loads(receipt.read_text())
            if (not isinstance(previous, dict) or previous.get('version') != version
                    or previous.get('archive') != archive.relative_to(folder).as_posix()
                    or previous.get('sha256') != sha256(archive)):
                print('Cached iOS platform receipt does not match; downloading a fresh package.', flush=True)
                return None
        except (OSError, ValueError):
            return None
    # Older caches had no receipt. Verify the DMG, then adopt it only after a
    # successful import and a check of the installed runtime version.
    return archive if verify_dmg(archive) else None


def import_archive(archive, version):
    for attempt in range(1, 4):
        result = subprocess.run(['xcodebuild', '-importPlatform', str(archive.resolve())])
        if result.returncode == 0 and installed(version):
            return True
        print(f'iOS platform import or version check failed ({attempt}/3).', flush=True)
        if attempt < 3:
            time.sleep(15)
    return False


def download_archive(folder, version):
    for attempt in range(1, 4):
        with tempfile.TemporaryDirectory(prefix='.ios-platform-', dir=folder.parent) as temporary:
            staging = Path(temporary) / 'package'
            staging.mkdir()
            result = subprocess.run(['xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', version,
                                     '-exportPath', str(staging.resolve())])
            archives = list(staging.rglob('*.dmg'))
            if result.returncode == 0 and len(archives) == 1 and verify_dmg(archives[0]):
                relative = archives[0].relative_to(staging)
                if folder.exists():
                    shutil.rmtree(folder)
                staging.rename(folder)
                return folder / relative
        print(f'iOS platform download or integrity check failed ({attempt}/3).', flush=True)
        if attempt < 3:
            time.sleep(15)
    raise RuntimeError('Could not download a complete, verified iOS ' + version + ' platform package.')


def install_platform(root, version='18.1'):
    root = Path(root).resolve()
    folder = root / 'build/ios-platform-cache'
    # The only recursive replacement is this explicitly scoped generated cache.
    if folder.is_symlink() or folder.parent.is_symlink() or folder.resolve().parent != (root / 'build').resolve():
        raise RuntimeError('Unsafe iOS platform cache path: ' + str(folder))
    folder.parent.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip()
    if sdk != version:
        raise RuntimeError(f'Selected iPhoneOS SDK is {sdk}; this workflow requires {version}.')
    if installed(version):
        print('iOS ' + version + ' platform and SDK are already available.', flush=True)
        return {'status': 'already-installed', 'runtime_version': version, 'sdk_version': sdk, 'cacheable': False}
    archive = cached_archive(folder, version)
    reused = archive is not None
    if archive is None or not import_archive(archive, version):
        archive = download_archive(folder, version)
        reused = False
        if not import_archive(archive, version):
            raise RuntimeError('iOS platform import did not produce the required available runtime: ' + version)
    receipt = {'version': version, 'archive': archive.relative_to(folder).as_posix(), 'sha256': sha256(archive)}
    (folder / 'platform-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return {'status': 'verified', 'runtime_version': version, 'sdk_version': sdk,
            'reused_download': reused, 'cacheable': True, **receipt}


def main():
    require_validation_enabled()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='18.1')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = install_platform(Path(__file__).resolve().parent.parent, args.version)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('cacheable=' + str(report['cacheable']).lower() + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
