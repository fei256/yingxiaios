"""Download a pinned input atomically and recover from an incomplete cached file."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

from build_validation import sha256


def download_verified(url, checksum, target):
    target = Path(target)
    if not re.fullmatch(r'[0-9a-f]{64}', checksum):
        raise ValueError('A pinned SHA-256 is required for ' + target.name)
    if target.is_symlink():
        raise RuntimeError('Refusing to download over a symlink: ' + str(target))
    if target.is_file() and sha256(target) == checksum:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.dependency-', dir=target.parent) as directory:
        temporary = Path(directory) / 'download'
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--retry-all-errors',
                        '--connect-timeout', '30', '--max-time', '1800',
                        '--output', str(temporary), '--', url], check=True)
        if sha256(temporary) != checksum:
            raise RuntimeError('Downloaded input SHA-256 mismatch: ' + target.name)
        temporary.replace(target)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    download_verified(args.url, args.sha256, args.output)


if __name__ == '__main__':
    main()
