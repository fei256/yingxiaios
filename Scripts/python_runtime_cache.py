"""Bind the assembled iOS Python runtime to its recipe, toolchain and output hashes."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from build_validation import sha256

RECIPE_INPUTS = [
    'Scripts/build-apple-python.sh', 'Scripts/build-apple-python-wheels.sh',
    'Scripts/build-apple-python-cryptography.sh', 'Scripts/fetch-build-python.sh',
    'Scripts/python_runtime_cache.py', 'Scripts/verified_download.py', 'Scripts/build_validation.py',
    'Runtime/PythonHost/requirements.txt', 'Config/Python/PrivacyInfo.xcprivacy',
]


def recipe_fingerprint(root, toolchain):
    digest = hashlib.sha256(json.dumps(toolchain, sort_keys=True).encode())
    for name in RECIPE_INPUTS:
        digest.update(name.encode())
        digest.update((Path(root) / name).read_bytes())
    return digest.hexdigest()


def runtime_checksums(runtime):
    runtime = Path(runtime)
    checksums = {}
    for path in sorted(runtime.rglob('*')):
        if path.name in ('.prepared', '.prepared.json', '.prepared.json.tmp'):
            continue
        if path.is_symlink():
            checksums[path.relative_to(runtime).as_posix()] = 'symlink:' + os.readlink(path)
        elif path.is_file():
            checksums[path.relative_to(runtime).as_posix()] = sha256(path)
    return checksums


def cache_ready(runtime, fingerprint):
    runtime = Path(runtime)
    receipt = runtime / '.prepared.json'
    if not receipt.is_file() or not (runtime / 'Frameworks/Python.framework/Python').is_file():
        return False
    try:
        previous = json.loads(receipt.read_text())
        return (isinstance(previous, dict) and previous.get('format') == 1 and previous.get('recipe') == fingerprint
                and bool(previous.get('outputs')) and previous['outputs'] == runtime_checksums(runtime))
    except (OSError, ValueError):
        return False


def reset_recipe_work(root, fingerprint):
    if not re.fullmatch(r'[0-9a-f]{64}', fingerprint):
        raise ValueError('Invalid Python recipe fingerprint.')
    base = Path(root).resolve() / 'build/apple-python'
    work = base / ('ios16.1-' + fingerprint)
    # Only this generated recipe directory is disposable. Other platform builds
    # and any files from older layouts remain untouched.
    if base.parent.is_symlink() or base.is_symlink() or work.is_symlink() or work.resolve().parent != base.resolve():
        raise RuntimeError('Unsafe Python recipe cache path: ' + str(work))
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    return work


def prepare_python_runtime(root):
    root = Path(root)
    host = os.environ.get('HOST_PYTHON')
    if not host:
        host = subprocess.check_output(['bash', 'Scripts/fetch-build-python.sh'], cwd=root, text=True).strip()
    toolchain = {
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'sdk': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True).strip(),
        'clang': subprocess.check_output(['xcrun', '--sdk', 'iphoneos', 'clang', '--version'], text=True).strip(),
        'host_python': subprocess.check_output([host, '-I', '-c', 'import sys; print(sys.version)'], text=True).strip(),
        'target': 'arm64-apple-ios16.1',
    }
    fingerprint = recipe_fingerprint(root, toolchain)
    runtime = root / 'build/ApplePython/iphoneos'
    if cache_ready(runtime, fingerprint):
        print('Apple Python runtime recipe and all cached outputs are verified.', flush=True)
        return
    work = reset_recipe_work(root, fingerprint)
    env = dict(os.environ, HOST_PYTHON=host, APPLE_PYTHON_WORK=str(work))
    subprocess.run(['bash', 'Scripts/build-apple-python.sh', 'ios'], cwd=root, env=env, check=True)
    outputs = runtime_checksums(runtime)
    if not outputs or not (runtime / 'Frameworks/Python.framework/Python').is_file():
        raise RuntimeError('Python build did not produce a complete runtime.')
    receipt = {'format': 1, 'recipe': fingerprint, 'toolchain': toolchain, 'outputs': outputs}
    temporary = runtime / '.prepared.json.tmp'
    temporary.write_text(json.dumps(receipt, indent=2) + '\n')
    temporary.replace(runtime / '.prepared.json')
