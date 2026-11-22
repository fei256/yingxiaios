#!/usr/bin/env python3
"""Prepare production declarations for Foundation-only macOS regression checks."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
output = root / "build/ci/settings-lifecycle"
output.mkdir(parents=True, exist_ok=True)


def declaration(filename: str, marker: str) -> str:
    text = (root / filename).read_text(encoding="utf-8")
    start = text.index(marker)
    end = text.index("\n}", start) + 2
    return text[start:end]


models = "Sources/TVCore/Models.swift"
danmaku = "Sources/TVCore/Danmaku.swift"
catalog = "App/CatalogDanmakuView.swift"
native_model = declaration(catalog, "@MainActor @Perceptible final class CatalogDanmakuModel {")
# Only the observation macros are omitted from the CLI host. The production
# initializer, notification, reload, persistence and request methods are intact.
native_model = native_model.replace("@Perceptible ", "").replace("@PerceptionIgnored ", "")
generated = "import Foundation\n\n" + "\n\n".join([
    declaration(models, "public enum JSONValue:"),
    declaration(danmaku, "public enum DanmakuStyle {"),
    native_model,
]) + "\n"
(output / "ProductionDeclarations.swift").write_text(generated, encoding="utf-8")
sources = [models, danmaku, catalog, "Sources/TVCore/LocalDanmakuPreferences.swift",
           "Sources/TVCore/DanmakuTrackSelection.swift", "Sources/TVCore/TMDBServiceSettings.swift",
           "App/PlayerBadgeRules.swift", "Sources/TVCore/LocalDetailEpisodeNumbers.swift",
           "App/LocalMediaBadgeStore.swift", "App/LocalMediaBadgeImporter.swift", "App/BoundedHTTPResponse.swift"]
evidence = [{"path": filename, "sha256": hashlib.sha256((root / filename).read_bytes()).hexdigest()}
            for filename in sources]
(output / "production-sources.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
print(f"Prepared production settings declarations at {output}")
