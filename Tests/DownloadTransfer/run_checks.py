#!/usr/bin/env python3
"""Compile the production Swift downloader, run loopback tests, then clean up."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from fixture_server import running_server


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def source_section(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError(f"Production helper anchors changed: {start}")
    return start + source.split(start, 1)[1].split(end, 1)[0]


def prepare_support(path: Path) -> None:
    library = (ROOT / "Sources/TVCore/Downloads.swift").read_text(encoding="utf-8")
    remux = (ROOT / "Sources/TVCore/Remux.swift").read_text(encoding="utf-8")
    capacity = source_section(
        library,
        "    nonisolated static func availableCapacity(at url: URL) -> Int64? {",
        "    /// Keeps a downloaded HDR MKV",
    )
    rewrap = source_section(
        library,
        "    nonisolated static func rewrap(",
        "    /// The MP4 a downloaded MKV",
    )
    names = re.findall(r'(?m)^    nonisolated static let rewrappedName = .+$', library)
    if len(names) != 1:
        raise RuntimeError("Production rewrapped filename anchor changed")
    predicate = source_section(
        remux,
        "    public static func handles(name: String) -> Bool {",
        "    /// Whether repackaging shows a picture",
    )
    support = (HERE / "Support.swift.template").read_text(encoding="utf-8")
    support = support.replace("// {{DOWNLOAD_LIBRARY_HELPERS}}", capacity + rewrap + names[0])
    support = support.replace("// {{REMUX_NAME_HELPER}}", predicate)
    path.write_text(support, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="Test HTTP fixtures only; does not execute Swift")
    parser.add_argument("--report", type=Path, help="Save executed production checks as JSON")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.discover(str(HERE), pattern="test_fixture_server.py")
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    if platform.system() != "Darwin":
        print("Production Swift checks require macOS/Xcode. --self-test only validates HTTP fixtures.", file=sys.stderr)
        return 2
    inputs = [
        ROOT / "Sources/TVCore/DownloadTransfer.swift",
        ROOT / "Sources/TVCore/MediaPayload.swift",
        ROOT / "Sources/TVCore/Downloads.swift",
        ROOT / "Sources/TVCore/Remux.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="yingxia-download-checks-") as temporary:
        work = Path(temporary)
        support = work / "Support.swift"
        prepare_support(support)
        executable = work / "download-transfer-checks"
        report = work / "results.json"
        subprocess.run(
            [
                "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                "-enable-bare-slash-regex", "-target", f"{platform.machine()}-apple-macosx13.0",
                str(inputs[0]), str(inputs[1]), str(support), str(HERE / "checks.swift"),
                "-o", str(executable),
            ],
            check=True,
            cwd=ROOT,
            timeout=120,
        )
        with running_server() as (_, base):
            subprocess.run([str(executable), base, str(work / "downloads"), str(report)], check=True, timeout=150)
        results = json.loads(report.read_text(encoding="utf-8"))
        results["productionSources"] = {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs
        }
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
