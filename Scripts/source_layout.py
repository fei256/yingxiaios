"""Validate the source aliases and script modes before expensive native builds."""
import os
from pathlib import Path
import re
import subprocess

SOURCE_LINKS = {
    'Packages/TVCore/Package.swift': '../../Package.swift',
    'Packages/TVCore/Sources': '../../Sources',
    'Packages/TVCore/Vendor': '../../Vendor',
}


def git_modes(root):
    root = Path(root)
    if not (root / '.git').exists():
        return {}
    output = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--stage', '-z'])
    modes = {}
    for entry in output.split(b'\0'):
        if not entry:
            continue
        metadata, name = entry.split(b'\t', 1)
        mode, _, stage = metadata.decode().split()
        if stage != '0':
            raise RuntimeError('Resolve Git merge conflicts before building.')
        modes[name.decode('utf-8')] = mode
    return modes


def check_source_layout(root, *, windows=None):
    root = Path(root)
    windows = os.name == 'nt' if windows is None else windows
    modes = git_modes(root)
    errors = []
    for name, target in SOURCE_LINKS.items():
        path = root / name
        if modes and modes.get(name) != '120000':
            errors.append(name + ': Git must store this alias as a 120000 symlink.')
        elif modes.get(name) == '120000' and (root / '.git').exists():
            staged = subprocess.check_output(['git', '-C', str(root), 'show', ':' + name])
            if staged != target.encode():
                errors.append(name + ': staged Git link target differs from ' + target)
        if path.is_symlink():
            if os.readlink(path).replace('\\', '/') != target or not path.exists():
                errors.append(name + ': wrong or missing link target; expected ' + target)
        elif not (windows and modes.get(name) == '120000' and path.is_file()
                  and path.read_bytes() == target.encode()):
            errors.append(name + ': source link was flattened or lost. Restore it with a Git checkout; '
                          'a text file containing a path is not a macOS source link.')
    scripts = []
    for path in sorted((root / 'Scripts').iterdir()):
        if not path.is_file() or path.suffix not in ('.sh', '.py'):
            continue
        shebang = path.read_bytes().startswith(b'#!')
        if path.suffix == '.sh' and not shebang:
            errors.append(path.name + ': missing shell interpreter line.')
        if not shebang:
            continue
        name = path.relative_to(root).as_posix()
        scripts.append(name)
        if modes and modes.get(name) != '100755':
            errors.append(name + ': Git executable mode must be 100755 (git update-index --chmod=+x).')
        if not windows and not path.stat().st_mode & 0o111:
            errors.append(name + ': checkout has no executable permission (chmod +x).')
        if path.suffix == '.sh' and b'\r\n' in path.read_bytes():
            errors.append(name + ': shell scripts require LF line endings.')
    manifest = root / 'Package.swift'
    if not manifest.is_file() or not re.match(r'// swift-tools-version:\s*6\.0\s*\n', manifest.read_text()):
        errors.append('Package.swift must begin with // swift-tools-version: 6.0 for Xcode 16.1.')
    return {'source_links': SOURCE_LINKS, 'executable_scripts': scripts,
            'windows_git_placeholders_allowed': windows, 'errors': errors}
