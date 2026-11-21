# Download transfer HTTP regression checks

Run from the repository root on macOS with Xcode 16 selected:

```sh
python3 -B Tests/DownloadTransfer/run_checks.py --report build/ci/download-transfer-checks.json
```

The runner compiles the actual `Sources/TVCore/DownloadTransfer.swift` and
`MediaPayload.swift` with Swift 6. It also inserts the original storage/rewrap
helpers from `Downloads.swift` and the original filename predicate from
`Remux.swift` into `Support.swift.template`. The template provides application
metadata/logging fixtures and traps if native DASH or remux work is entered.
No downloader, retry logic, HLS parser, range writer or progress implementation
is copied into the harness. Compilation and runtime failures fail the command.

The 19 production Swift checks exercise a 1024-byte interrupted non-Range body
followed by exactly 4108 bytes, mirror retries, saved non-Range progress,
cancellation cleanup and restart, gzip decoding, close-delimited and chunked
unknown lengths, three production-sized ranges, ignored/mismatched ranges,
HLS default/available/in-band audio selections from multi-audio groups, local
master/media playlists, shared AES keys, initialization maps, explicit/implicit
byte ranges, cancellation and resume, truncated keys/ranges, old video-only
plan migration, and explicit failures for unsupported/incomplete audio.
Source headers must reach both tracks and their assets. The JSON report records
executed checks and SHA-256 hashes of the production sources compiled.

Fixtures only, usable on Windows without Swift:

```powershell
python -B Tests/DownloadTransfer/run_checks.py --self-test
```

Those seven HTTP fixture checks do not compile or execute Swift. They do not
establish that the production regressions pass. The full command requires
macOS/Xcode and runs the real Foundation URLSession downloader over loopback HTTP.
All server threads, generated Swift support, executables and downloaded fixtures
are stopped/removed on completion or failure; only an explicitly requested JSON
report is retained. Fixtures verify transfer bytes and playlist references; Apple
playback and native remux/DASH decoding remain part of the iOS/device validation.
