"""Fingerprint tracked CI inputs and preserve unchanged source modification times."""
import argparse
import hashlib
import json
import os
from pathlib import Path

from build_resources import build_resources
from build_validation import sha256
from source_layout import git_modes


NATIVE_INPUTS = ('Scripts/', 'Vendor/', 'Runtime/PythonHost/', 'Config/Python/', 'Package.resolved')
BUILD_SETTINGS = ('Config/', 'Package.swift', 'Package.resolved', 'project.yml')


def tracked_modes(root):
    modes = git_modes(root)
    if not modes:
        raise RuntimeError('CI caching requires a Git checkout with tracked inputs.')
    return modes


def input_digest(root, name, mode):
    path = Path(root) / name
    if mode == '120000':
        data = os.readlink(path).encode('utf-8') if path.is_symlink() else path.read_bytes()
        return hashlib.sha256(data).hexdigest()
    if path.is_symlink() or not path.is_file():
        raise RuntimeError('Tracked cache input is missing or has become a link: ' + name)
    return sha256(path)


def fingerprint(root, modes, scopes):
    inputs = {
        name: {'mode': mode, 'sha256': input_digest(root, name, mode)}
        for name, mode in sorted(modes.items())
        if any(name.startswith(scope) if scope.endswith('/') else name == scope for scope in scopes)
    }
    if not inputs:
        raise RuntimeError('No tracked files matched the CI cache inputs.')
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode('utf-8')).hexdigest()
    return digest, len(inputs)


def cache_keys(root):
    modes = tracked_modes(root)
    native, native_count = fingerprint(root, modes, NATIVE_INPUTS)
    settings, settings_count = fingerprint(root, modes, BUILD_SETTINGS)
    resources = build_resources()
    return {
        'native': native,
        'settings': settings,
        'native_input_count': native_count,
        'settings_input_count': settings_count,
        'resources': {
            'physical_cores': resources['physical_cores'],
            'memory_gib': round(resources['memory_bytes'] / 1024 ** 3, 1),
            'jobs': resources['jobs'],
        },
    }


def save_timestamps(root, state_path):
    root = Path(root).resolve()
    files = {}
    for name, mode in sorted(tracked_modes(root).items()):
        path = root / name
        if mode == '120000' or path.is_symlink() or not path.is_file():
            continue
        if not path.resolve().is_relative_to(root):
            raise RuntimeError('Source timestamp input is outside the checkout: ' + name)
        files[name] = {'sha256': sha256(path), 'mtime_ns': path.stat().st_mtime_ns}
    state_path = Path(state_path)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps({'format': 1, 'files': files}, sort_keys=True) + '\n')
    return {'status': 'saved', 'files': len(files)}


def restore_timestamps(root, state_path):
    root = Path(root).resolve()
    state_path = Path(state_path)
    if not state_path.is_file():
        return {'status': 'no-cache', 'restored': 0}
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        return {'status': 'invalid-cache', 'restored': 0}
    if not isinstance(state, dict) or state.get('format') != 1 or not isinstance(state.get('files'), dict):
        return {'status': 'invalid-cache', 'restored': 0}
    restored = changed = 0
    # Only current tracked paths are eligible; cached path names cannot escape the checkout.
    for name, mode in sorted(tracked_modes(root).items()):
        path = root / name
        entry = state['files'].get(name)
        if mode == '120000' or path.is_symlink() or not path.is_file() or not isinstance(entry, dict):
            continue
        if not path.resolve().is_relative_to(root):
            raise RuntimeError('Source timestamp input is outside the checkout: ' + name)
        mtime = entry.get('mtime_ns')
        if type(mtime) is not int or mtime < 0:
            continue
        if entry.get('sha256') != sha256(path):
            changed += 1
            continue
        os.utime(path, ns=(path.stat().st_atime_ns, mtime))
        restored += 1
    return {'status': 'restored', 'restored': restored, 'changed': changed}


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('keys', 'save-timestamps', 'restore-timestamps'))
    parser.add_argument('--state', type=Path, default=root / 'build/ci/source-timestamps.json')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.command == 'keys':
        report = cache_keys(root)
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write(f"native={report['native']}\nsettings={report['settings']}\n")
        if os.environ.get('GITHUB_ENV'):
            with open(os.environ['GITHUB_ENV'], 'a') as output:
                output.write(f"JOBS={report['resources']['jobs']}\n")
    elif args.command == 'save-timestamps':
        report = save_timestamps(root, args.state)
    else:
        report = restore_timestamps(root, args.state)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
