"""Enumerate source inputs consistently in Git checkouts and extracted source archives."""
from pathlib import Path
import os

from build_validation import sha256
from source_layout import git_modes

NATIVE_DIRECTORIES = [
    'build/FFmpeg/FFmpeg.xcframework',
    'Vendor/DiscNative/DiscNative.xcframework',
    'Vendor/NativeASR/TVASR.xcframework',
    'build/ApplePython/iphoneos',
    'build/RuntimeDependencies/NodeMobile/NodeMobile.xcframework/ios-arm64/NodeMobile.framework',
]


def source_paths(root):
    root = Path(root)
    excluded = {'.git', '.build', 'build', 'artifacts', 'exports', 'node_modules',
                '__pycache__', '.swiftpm', 'xcuserdata', '.wrangler'}
    files = []
    for directory, folders, names in os.walk(root, followlinks=False):
        folders[:] = [name for name in folders if name not in excluded
                      and not name.endswith(('.xcodeproj', '.xcworkspace', '.xcframework', '.framework'))]
        for name in folders:
            if (Path(directory) / name).is_symlink():
                files.append((Path(directory) / name).relative_to(root).as_posix())
        folders[:] = [name for name in folders if not (Path(directory) / name).is_symlink()]
        for name in names:
            path = Path(directory) / name
            if name == '.DS_Store' or name.startswith(('.env', '.dev.vars')) or name.endswith(('.pyc', '.log')):
                continue
            if path.is_file() or path.is_symlink():
                files.append(path.relative_to(root).as_posix())
    return sorted(files)


def source_checksums(root):
    root = Path(root)
    modes = git_modes(root) if os.name == 'nt' else {}
    checksums = {}
    for name in source_paths(root):
        path = root / name
        if path.is_symlink():
            checksums[name] = 'symlink:' + os.readlink(path)
        else:
            checksums[name] = sha256(path)
            if path.suffix in ('.sh', '.py') and path.read_bytes().startswith(b'#!'):
                checksums['@mode/' + name] = modes.get(name, 'untracked') if os.name == 'nt' else oct(path.stat().st_mode & 0o111)
        if modes.get(name) == '120000':
            checksums['@mode/' + name] = '120000'
    return checksums


def native_checksums(root):
    root = Path(root)
    checksums = {}
    for directory in NATIVE_DIRECTORIES:
        for path in sorted((root / directory).rglob('*')):
            name = path.relative_to(root).as_posix()
            if path.is_symlink():
                checksums[name] = 'symlink:' + os.readlink(path)
            elif path.is_file():
                checksums[name] = sha256(path)
    return checksums


def changed_inputs(before, after):
    return [name for name in sorted(before.keys() | after.keys()) if before.get(name) != after.get(name)]
