"""Write the Payload ZIP with explicit UTF-8 names and preserved Unix file modes."""
import os
from pathlib import Path
import stat
import time
import zipfile


def write_payload_zip(payload, output):
    payload, output = Path(payload), Path(output)
    if payload.name != 'Payload' or not payload.is_dir() or payload.is_symlink():
        raise ValueError('IPA input must be a real Payload directory')
    paths = [payload]
    for directory, folders, files in os.walk(payload, followlinks=False):
        paths.extend(Path(directory) / name for name in folders + files)
    created = False
    try:
        with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6,
                             strict_timestamps=False) as archive:
            created = True
            for path in sorted(paths):
                name = path.relative_to(payload.parent).as_posix()
                if path.is_symlink():
                    info = path.lstat()
                    stamp = time.localtime(max(info.st_mtime, 315532800))[:6]
                    member = zipfile.ZipInfo(name, stamp)
                    member.create_system = 3
                    member.external_attr = (stat.S_IFLNK | stat.S_IMODE(info.st_mode)) << 16
                    archive.writestr(member, os.readlink(path).encode('utf-8'))
                else:
                    archive.write(path, name)
    except BaseException:
        if created:
            output.unlink(missing_ok=True)
        raise
