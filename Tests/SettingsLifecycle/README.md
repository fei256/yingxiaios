These checks run production settings and native import logic with controlled I/O.

From the repository root:

```powershell
node --test Tests/SettingsLifecycle/ai-revision.test.mjs
```

The JS tests call the real MobileServices settings/AI methods. Only its disk-cache
constructor and provider HTTP boundary are replaced with in-memory fixtures.
They cover unrelated settings, duplicate/partial AI patches, cache reuse,
transcription, and rejection of genuinely changed AI configuration.

On a Mac with Xcode 16.4 or newer, compile and execute the Swift checks:

```sh
python3 Tests/SettingsLifecycle/prepare-native-checks.py
xcrun swiftc -swift-version 6 -parse-as-library \
  build/ci/settings-lifecycle/ProductionDeclarations.swift \
  Sources/TVCore/LocalDanmakuPreferences.swift Sources/TVCore/DanmakuTrackSelection.swift \
  Sources/TVCore/TMDBServiceSettings.swift Sources/TVCore/LocalDetailEpisodeNumbers.swift \
  App/PlayerBadgeRules.swift App/LocalMediaBadgeStore.swift App/BoundedHTTPResponse.swift App/LocalMediaBadgeImporter.swift \
  Tests/SettingsLifecycle/Support.swift Tests/SettingsLifecycle/checks.swift \
  -o build/ci/settings-lifecycle/checks
build/ci/settings-lifecycle/checks build/ci/settings-lifecycle/results.json
```

The preparation step extracts the unchanged JSONValue and DanmakuStyle
dependencies, and the production CatalogDanmakuModel declaration. Its Perception
annotations are omitted only in the Foundation CLI host; its initializer,
notification and preference reload paths are executed. The application build
still needs to compile the original Perception annotations for iOS 16.1.
Unrelated danmaku provider/cache types are fixtures that perform no network I/O.
TMDB preferences, media badge rules/store and the native badge importer are
compiled directly from complete production files. Badge requests use URLProtocol
fixtures and an isolated, removed UserDefaults suite. No personal configuration,
external service, or listening server is used.

The Swift checks cover synchronous restored preference refresh, direct player
edits, normalized appearance, test/save credential parity, and delayed/cancelled
badge imports. The normal app build must also typecheck the async backup
coordinator and the SwiftUI settings lifecycle callbacks. This Windows checkout
does not include Swift or an iOS simulator; do not report those checks as passed
until the Mac run finishes.
