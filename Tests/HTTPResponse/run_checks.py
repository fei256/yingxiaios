"""Run the actual Swift response limiter against bounded loopback HTTP fixtures."""
import argparse
from contextlib import contextmanager
import gzip
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

LIMIT = 4 * 1024 * 1024
SMALL = b'{"fixture":true}'


class Fixture(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.strip('/')
        try:
            if path == 'slow':
                self.send_response(200); self.send_header('Transfer-Encoding', 'chunked'); self.end_headers()
                while not self.server.stop_event.is_set():
                    self.wfile.write(b'1\r\nx\r\n'); self.wfile.flush()
                    self.server.stop_event.wait(0.05)
                return
            if path == 'chunked':
                self.send_response(200); self.send_header('Transfer-Encoding', 'chunked'); self.end_headers()
                chunk = b'x' * 4096
                for _ in range(LIMIT // len(chunk) + 2):
                    self.wfile.write(b'1000\r\n' + chunk + b'\r\n')
                self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
                return
            payload = {'small': SMALL, 'exact': b'x' * LIMIT,
                       'declared': b'x' * (LIMIT + 1), 'unknown': b'close-delimited',
                       'status': b'error', 'gzip': gzip.compress(b'x' * (LIMIT + 1024))}[path]
            self.send_response(503 if path == 'status' else 200)
            if path == 'gzip': self.send_header('Content-Encoding', 'gzip')
            if path == 'unknown':
                self.send_header('Connection', 'close'); self.close_connection = True
            else:
                self.send_header('Content-Length', str(len(payload)))
            self.end_headers(); self.wfile.write(payload); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, KeyError):
            self.close_connection = True


@contextmanager
def fixture_server():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    server.stop_event = threading.Event()
    worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
    try:
        yield server
    finally:
        server.stop_event.set(); server.shutdown(); server.server_close(); worker.join(timeout=5)


class FixtureChecks(unittest.TestCase):
    def test_fixture_response_shapes(self):
        with fixture_server() as server:
            for path, length in [('small', len(SMALL)), ('exact', LIMIT), ('declared', LIMIT + 1),
                                 ('chunked', LIMIT + 8192), ('unknown', 15), ('status', 5)]:
                with self.subTest(path=path):
                    connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
                    try:
                        connection.request('GET', '/' + path); response = connection.getresponse()
                        self.assertEqual(response.status, 503 if path == 'status' else 200)
                        self.assertEqual(len(response.read()), length)
                    finally:
                        connection.close()

    def test_fixture_decompression_expands_beyond_the_limit(self):
        with fixture_server() as server:
            connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
            try:
                connection.request('GET', '/gzip'); response = connection.getresponse()
                encoded = response.read()
                self.assertLess(len(encoded), LIMIT)
                self.assertEqual(len(gzip.decompress(encoded)), LIMIT + 1024)
            finally:
                connection.close()

    def test_fixture_stream_remains_active_before_cancellation(self):
        with fixture_server() as server:
            connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
            try:
                connection.request('GET', '/slow'); response = connection.getresponse()
                started = time.monotonic()
                self.assertEqual(response.read(5), b'xxxxx')
                self.assertGreater(time.monotonic() - started, 0.1)
            finally:
                connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(FixtureChecks))
        return 0 if result.wasSuccessful() else 1
    if sys.platform != 'darwin' or not shutil.which('xcrun'):
        raise SystemExit('Production Swift checks require macOS/Xcode; --self-test only verifies the HTTP fixtures.')
    root = Path(__file__).resolve().parents[2]
    production = root / 'App/BoundedHTTPResponse.swift'
    with tempfile.TemporaryDirectory(prefix='yingxia-http-response-') as directory, fixture_server() as server:
        executable = Path(directory) / 'checks'
        result_path = Path(directory) / 'results.json'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(production),
                        str(root / 'Tests/HTTPResponse/checks.swift'), '-o', str(executable)], check=True)
        subprocess.run([str(executable), f'http://127.0.0.1:{server.server_port}/', str(result_path)], check=True, timeout=60)
        checks = json.loads(result_path.read_text(encoding='utf-8'))
        report = {'kind': 'production-swift-urlsession-loopback', 'checks': checks,
                  'passed': all(item['passed'] for item in checks),
                  'productionSources': {'App/BoundedHTTPResponse.swift': hashlib.sha256(production.read_bytes()).hexdigest()}}
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'checks': len(checks), 'passed': report['passed']}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
