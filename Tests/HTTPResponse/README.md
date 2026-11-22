Run `python3 -B Tests/HTTPResponse/run_checks.py --report results.json` on macOS
with Xcode selected. This compiles the complete production response limiter and
executes nine URLSession checks over loopback HTTP: original bytes, exactly four
MiB, declared/chunked/gzip oversize, unknown length, HTTP failure, cancellation
and a continuously streaming response with a wall-clock deadline. The server,
temporary executable and intermediate results are removed on every exit path.

`python -B Tests/HTTPResponse/run_checks.py --self-test` also works on Windows.
It validates the fixtures only and does not execute Swift or prove that the
production regression passes.
