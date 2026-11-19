#!/usr/bin/env python3
"""Prepare the pinned dependencies and Swift packages needed for the iOS IPA build."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

from build_validation import ensure_directory_link, require_validation_enabled
from python_runtime_cache import prepare_python_runtime
from source_layout import check_source_layout

ROOT = Path(__file__).resolve().parent.parent


def main():
    require_validation_enabled()
    parser = argparse.ArgumentParser(description=__doc__)
    av3a = parser.add_mutually_exclusive_group()
    av3a.add_argument('--av3a-archive', type=Path, help='Locally obtained AV3A reference archive, according to its terms.')
    av3a.add_argument('--fetch-av3a', action='store_true', help='Fetch the pinned AV3A input from upstream under its terms.')
    parser.add_argument('--skip-package-resolution', action='store_true', help='Prepare native dependencies and the project; resolve Swift packages separately.')
    args = parser.parse_args()
    if sys.version_info < (3, 10):
        raise SystemExit('Python 3.10 or newer is required.')
    layout = check_source_layout(ROOT)
    if layout['errors']:
        raise SystemExit('\n'.join(layout['errors']))
    for name in ['xcrun', 'xcodebuild', 'git', 'curl', 'rg', 'pkg-config', 'patch']:
        if shutil.which(name) is None:
            raise SystemExit('Missing build tool: ' + name + '. See README.md.')
    if not (os.environ.get('XCODEGEN') or shutil.which('xcodegen')
            or (ROOT / 'build/tools/xcodegen/xcodegen/bin/xcodegen').is_file()):
        raise SystemExit('Install XcodeGen or set XCODEGEN. See README.md.')
    subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], check=True)
    command = [sys.executable, 'Scripts/fetch-vendor-dependencies.py']
    if args.av3a_archive:
        command += ['--av3a-archive', str(args.av3a_archive.resolve())]
    if args.fetch_av3a:
        command += ['--fetch-av3a']
    subprocess.run(command, cwd=ROOT, check=True)
    node = ROOT / 'build/RuntimeDependencies/NodeMobile'
    node_inputs = [node / 'NodeMobile.xcframework/ios-arm64/NodeMobile.framework/NodeMobile', node / 'LICENSE.node']
    if not all(path.is_file() for path in node_inputs):
        subprocess.run(['bash', 'Scripts/fetch-node-mobile.sh', 'ios'], cwd=ROOT, check=True)
        ensure_directory_link(node, (ROOT / 'build/NodeMobile').resolve())
    if not all(path.is_file() for path in node_inputs):
        raise SystemExit('NodeMobile cache did not produce the required device binary and license.')
    prepare_python_runtime(ROOT)
    env = dict(os.environ, TVBOX_FFMPEG_SLICES='ios', TVBOX_FFMPEG_CACHE=str(ROOT / 'build/FFmpeg/cache'))
    subprocess.run(['bash', 'Scripts/build-ios-disc.sh'], cwd=ROOT, env=env, check=True)
    subprocess.run(['bash', 'Scripts/build-apple-ffmpeg.sh'], cwd=ROOT, env=env, check=True)
    link = ROOT / 'Vendor/FFmpeg/FFmpeg.xcframework'
    ensure_directory_link(link, '../../build/FFmpeg/FFmpeg.xcframework')
    subprocess.run([sys.executable, 'Scripts/prepare-ios-asr.py'], cwd=ROOT, check=True)
    subprocess.run([sys.executable, 'Scripts/generate-ios-project.py'], cwd=ROOT, check=True)
    resolved = ROOT / 'Yingxia-iOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    resolved.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'Package.resolved', resolved)
    if args.skip_package_resolution:
        print('Native dependencies and project prepared; Swift package resolution was skipped.')
        return
    subprocess.run(['xcodebuild', '-resolvePackageDependencies', '-project', 'Yingxia-iOS.xcodeproj',
                    '-scheme', 'TVBox-iOS', '-clonedSourcePackagesDirPath', 'build/SourcePackages',
                    '-onlyUsePackageVersionsFromResolvedFile'], cwd=ROOT, check=True)
    print('Dependencies prepared. Run python3 Scripts/build-ios-ipa.py --build-number 1')


if __name__ == '__main__':
    main()
