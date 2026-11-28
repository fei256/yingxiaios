# Runtime lifecycle regression checks

These checks execute the Foundation production code used by `EmbeddedNodeHost` and
`ScriptRuntime`. Transport closures inject completion, timeout, rebind and host-exit
responses; controlled async gates exercise same-key startup, cancellation and cleanup.
They do not launch NodeMobile or replace native iOS validation.

On macOS with the build's Xcode selected:

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/TVCore/EpisodeSkip.swift Sources/TVCore/RemoteEpisodeSkip.swift Sources/TVCore/PlaybackOperationScope.swift Sources/TVCore/NodeSourceCompletion.swift Sources/TVCore/RuntimeStartupRegistry.swift \
  Tests/RuntimeLifecycle/checks.swift -o build/ci/runtime-lifecycle-checks
build/ci/runtime-lifecycle-checks build/ci/runtime-lifecycle-checks.json
```
