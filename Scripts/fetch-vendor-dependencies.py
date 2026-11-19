#!/usr/bin/env python3
"""Retrieve pinned dependency inputs, preserving their upstream SHA-256 values."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile

from build_validation import sha256
from verified_download import download_verified

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return sha256(path)


def prepare_av3a(archive):
    vendor = ROOT / 'Vendor/AV3A'
    inventory = json.loads((vendor / 'SOURCE-INVENTORY.json').read_text())
    if all((vendor / item['path']).is_file() and digest(vendor / item['path']) == item['sha256']
           for item in inventory['files']):
        return
    if archive is None:
        raise SystemExit('AV3A reference input is not distributed in this package. Read Vendor/AV3A/UPSTREAM.md, '
                         'obtain the pinned archive under its terms, then pass --av3a-archive /path/to/archive.tar.gz.')
    if digest(archive) != inventory['archive_sha256']:
        raise SystemExit('AV3A archive SHA-256 mismatch')
    with tarfile.open(archive) as source:
        files = {item.name: item for item in source.getmembers() if item.isfile()}
        for item in inventory['files']:
            suffix = '/' + item['upstream_path']
            matches = [member for name, member in files.items() if name.endswith(suffix)]
            if len(matches) != 1:
                raise SystemExit('Missing or ambiguous AV3A member: ' + item['upstream_path'])
            data = source.extractfile(matches[0]).read()
            if hashlib.sha256(data).hexdigest() != item['sha256']:
                raise SystemExit('AV3A source member SHA-256 mismatch: ' + item['path'])
            destination = vendor / item['path']
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    av3a = parser.add_mutually_exclusive_group()
    av3a.add_argument('--av3a-archive', type=Path, help='Locally obtained pinned AV3A archive; see its upstream terms.')
    av3a.add_argument('--fetch-av3a', action='store_true', help='Fetch the pinned AV3A archive from its recorded upstream; its terms apply.')
    args = parser.parse_args()
    if args.fetch_av3a:
        inventory = json.loads((ROOT / 'Vendor/AV3A/SOURCE-INVENTORY.json').read_text())
        url = inventory['repository'].replace('https://github.com/', 'https://codeload.github.com/') + '/tar.gz/' + inventory['commit']
        args.av3a_archive = download_verified(url, inventory['archive_sha256'],
                                            ROOT / 'build/downloads' / ('av3a-' + inventory['commit'] + '.tar.gz'))
    prepare_av3a(args.av3a_archive)
    lock = json.loads((ROOT / 'Vendor/dependency-downloads.json').read_text())
    for item in lock['archives']:
        target = ROOT / item['path']
        if not target.resolve().is_relative_to(ROOT):
            raise SystemExit('Invalid dependency path')
        if target.is_file() and digest(target) == item['sha256']:
            print('Ready: ' + item['path'])
            continue
        download_verified(item['url'], item['sha256'], target)
        print('Prepared: ' + item['path'])


if __name__ == '__main__':
    main()
