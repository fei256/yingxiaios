#!/usr/bin/env python3
"""Check source layout on Windows or macOS without downloading dependencies."""
import argparse
import json
from pathlib import Path

from build_validation import require_validation_enabled
from source_layout import check_source_layout

require_validation_enabled()
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report', type=Path)
args = parser.parse_args()
report = check_source_layout(Path(__file__).resolve().parent.parent)
if args.report:
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
if report['errors']:
    raise SystemExit('\n'.join(report['errors']))
print(f"Source layout verified: {len(report['source_links'])} links, "
      f"{len(report['executable_scripts'])} executable scripts.")
