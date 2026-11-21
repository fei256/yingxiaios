# Playback stability regression checks

These checks compile the production reader coordinator, decoder resource/event primitives,
audio restart intent and circular buffer directly. They require Foundation and Dispatch;
there is no copied playback implementation or source-text/grep assertion.

On macOS CI:

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  Vendor/KSPlayer/Sources/KSPlayer/MEPlayer/PlaybackSynchronization.swift \
  Vendor/KSPlayer/Sources/KSPlayer/MEPlayer/CircularBuffer.swift \
  Tests/PlaybackStability/checks.swift \
  -o "$RUNNER_TEMP/playback-stability-checks"
"$RUNNER_TEMP/playback-stability-checks"
```

Run the same executable with Thread Sanitizer on a separate CI invocation when supported:
add `-sanitize=thread` to the compiler command. The checks cover signal-before-wait,
pause/seek/EOF/close handoff, reentrant completion, blocked producer/consumer shutdown,
native error wakeup, concurrent ring slots/counts, decoder identity/release and audio
pause/interruption restart gating. Worker deadlines turn missed wakeups into failures.

An Apple SDK build is additionally required to typecheck the real FFmpeg/VideoToolbox
and AVAudioEngine integrations. On an iPhone/iPad or audio-capable simulator, verify:

- Set volume before readiness, change audio format/episode/decoder, and inspect the new
  source node/output gain: it must retain the chosen volume.
- Change an output device's sample rate/channel count during play and while paused.
  Configuration changes must reconnect the audio graph and only resume requested playback.
- Interrupt with a phone call/Siri; pause during interruption; reject resumption when
  `shouldResume` is absent. Foreground/PiP must obey the same transport intent.
- Inject a fatal audio decoder error and an asynchronous VT error at EOF or during seek.
  The audio error must reach session recovery; VT fallback and close must drain callbacks
  without a native callback waiting on its own decoder worker.
- Decode embedded text/bitmap/closed-caption subtitles and repeatedly reopen/close.
  Instruments Allocations/ASan should show native contexts released after worker barriers.

This Windows workspace has no Swift compiler. A source inspection or successful iOS
link alone is not reported as an executed runtime regression test.
