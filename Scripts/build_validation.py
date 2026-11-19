"""Checks shared by the archive, dependency and package entry points."""
import hashlib
from pathlib import Path
import sys


def require_validation_enabled():
    if sys.flags.optimize:
        raise SystemExit('Required build checks cannot run with Python optimization. '
                         'Remove -O/-OO and unset PYTHONOPTIMIZE.')


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def ensure_directory_link(link, target):
    link = Path(link)
    target = Path(target)
    resolved = (link.parent / target).resolve()
    if not resolved.is_dir():
        raise RuntimeError('Dependency link target is missing: ' + str(resolved))
    if link.is_symlink():
        if link.resolve() == resolved:
            return
        link.unlink()
    elif link.exists():
        raise RuntimeError('Refusing to replace a real dependency path: ' + str(link))
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(target, target_is_directory=True)


def archive_failure_excerpt(log):
    lines = log.splitlines()
    indexes = set()
    for index, line in enumerate(lines):
        if 'error:' in line or 'fatal error:' in line:
            indexes.update(range(max(0, index - 2), min(len(lines), index + 4)))
            if len(indexes) >= 120:
                break
    context = [lines[index] if len(lines[index]) <= 1000 else lines[index][:1000] + ' [see full archive.log]'
               for index in sorted(indexes)]
    errors = '\n'.join(context)[:16000]
    tail = log[-8000:]
    return (errors + '\n\nArchive log tail:\n' + tail) if errors else tail
