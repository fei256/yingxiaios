"""Collect literal app icons and enum/array icon names for native OS validation."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
output = root / "build/ci/search-input/system-symbols.json"
names = {}
quoted = re.compile(r'"([^"\\]+)"')


def expression(source, start):
    depth = 0
    in_string = escaped = False
    for index in range(start, len(source)):
        char = source[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                return source[start:index]
            depth -= 1
        elif char in ",\n" and depth == 0:
            return source[start:index]
    return source[start:]


for path in sorted((root / "App").glob("*.swift")):
    source = path.read_text(encoding="utf-8")
    regions = [match.end() for match in re.finditer(r'\b(?:systemName|systemImage|symbol)\s*:\s*', source)]
    # Icon names also come from tab/option enum getters and category arrays.
    regions += [match.end() for match in re.finditer(r'\bvar\s+symbol\s*:\s*String\s*', source)]
    regions += [match.end() for match in re.finditer(r'\blet\s+symbols\s*=\s*', source)]
    for start in regions:
        region = expression(source, start)
        for match in quoted.finditer(region):
            if re.search(r'(?:==|!=)\s*$', region[:match.start()]):
                continue
            name = match[1]
            if re.fullmatch(r"[a-z0-9]+(?:[.][a-z0-9]+)*", name):
                location = f"{path.relative_to(root).as_posix()}:{source.count(chr(10), 0, start + match.start()) + 1}"
                names.setdefault(name, set()).add(location)
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps({"names": sorted(names), "locations": {name: sorted(locations) for name, locations in sorted(names.items())}}, indent=2) + "\n")
print(f"Prepared {len(names)} static app icons for native runtime verification.")
