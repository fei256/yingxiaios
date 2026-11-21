#!/usr/bin/env python3
"""Prepare an isolated host for production detail view geometry and image paint."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
output = root / "build/ci/detail-native"
output.mkdir(parents=True, exist_ok=True)
files = ["App/CatalogDetailAppearance.swift", "App/CatalogDetailTitle.swift", "App/TMDBArtwork.swift",
         "App/DetailReadability.swift", "App/PlayerTimelineTrack.swift", "App/CatalogDetailMetrics.swift",
         "Sources/TVCore/PlaybackCacheProgress.swift", "Sources/TVCore/TMDBServiceSettings.swift",
         "Sources/TVCore/TMDBNetworkTransport.swift"]
for filename in files + ["App/DiscoverArtwork.swift"]:
    source = (root / filename).read_text(encoding="utf-8")
    if filename == "App/DiscoverArtwork.swift":
        source = source.split("/// Only the cover responds to scroll;", 1)[0]
    source = source.replace("import Perception\n", "").replace("import TVCore\n", "")
    (output / Path(filename).name).write_text(source, encoding="utf-8")
sources = [str(output / Path(path).name) for path in files + ["App/DiscoverArtwork.swift"]]
sources += [str(root / "Tests/DetailAppearance" / name) for name in ["Harness.swift", "HarnessSupport.swift"]]
spec = {
    "name": "DetailChecks", "settings": {"base": {"SWIFT_VERSION": "6.0", "IPHONEOS_DEPLOYMENT_TARGET": "16.2", "CODE_SIGNING_ALLOWED": "NO"}},
    "targets": {
        "DetailChecks": {"type": "application", "platform": "iOS", "sources": [{"path": path} for path in sources],
                         "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.yingxia.detail-checks", "TARGETED_DEVICE_FAMILY": "1,2"}},
                         "info": {"path": str(output / "Info.plist"), "properties": {
                             "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False}, "UILaunchScreen": {},
                             "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
                         }}},
        "DetailHarnessTests": {"type": "bundle.ui-testing", "platform": "iOS", "sources": [{"path": str(root / "Tests/DetailAppearance/HarnessTests.swift")}],
                               "dependencies": [{"target": "DetailChecks"}]},
    },
    "schemes": {"DetailChecks": {"build": {"targets": {"DetailChecks": "all"}}, "test": {"targets": ["DetailHarnessTests"]}}},
}
(output / "project.json").write_text(json.dumps(spec, indent=2), encoding="utf-8")
print("Prepared production detail/title/artwork/timeline bodies with fixed fixtures.")
