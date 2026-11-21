"""Checks the controlled server on Windows too; these are not Swift regressions."""

import gzip
import http.client
import unittest
from urllib.parse import urlsplit

from fixture_server import (
    AUDIO_BODY, FILE_BODY, KEY_BODY, RANGE_BODY, VIDEO_BODY,
    master_playlist, media_playlist, running_server,
)


class HTTPFixtureTests(unittest.TestCase):
    def setUp(self):
        self.context = running_server()
        self.server, base = self.context.__enter__()
        endpoint = urlsplit(base)
        self.connection = http.client.HTTPConnection(endpoint.hostname, endpoint.port, timeout=3)

    def tearDown(self):
        self.connection.close()
        self.context.__exit__(None, None, None)

    def get(self, path, headers=None):
        self.connection.request("GET", path, headers={"X-Download-Fixture": "allowed", **(headers or {})})
        return self.connection.getresponse()

    def test_disconnect_then_complete_response(self):
        response = self.get("/plain-retry.mp4", {"Range": "bytes=0-65535"})
        self.assertEqual(response.read(), FILE_BODY)
        response = self.get("/plain-retry.mp4")
        with self.assertRaises(http.client.IncompleteRead) as failure:
            response.read()
        self.assertEqual(failure.exception.partial, FILE_BODY[:1024])
        self.assertEqual(response.getheader("Content-Length"), "4108")
        self.assertEqual(self.get("/plain-retry.mp4").read(), FILE_BODY)
        attempts = [item for item in self.server.state.snapshot()["requests"] if item["range"] is None]
        self.assertEqual([item["sent"] for item in attempts], [1024, 4108])

    def test_encoded_unknown_and_chunked_bodies(self):
        response = self.get("/coded.mp4")
        self.assertEqual(response.getheader("Content-Encoding"), "gzip")
        self.assertEqual(gzip.decompress(response.read()), FILE_BODY)
        response = self.get("/unknown.mp4")
        self.assertIsNone(response.getheader("Content-Length"))
        self.assertEqual(response.read(), FILE_BODY)
        response = self.get("/chunked.mp4")
        self.assertEqual(response.getheader("Transfer-Encoding"), "chunked")
        self.assertEqual(response.read(), FILE_BODY)

    def test_ranges_and_mismatched_content_range(self):
        response = self.get("/range.mp4", {"Range": "bytes=4194304-8388607"})
        self.assertEqual(response.status, 206)
        self.assertEqual(response.getheader("Content-Range"), f"bytes 4194304-8388607/{len(RANGE_BODY)}")
        self.assertEqual(response.read(), RANGE_BODY[4194304:8388608])
        response = self.get("/range-mismatch.mp4", {"Range": "bytes=0-127"})
        self.assertEqual(response.getheader("Content-Range"), f"bytes 1-127/{len(RANGE_BODY)}")
        self.assertEqual(response.read(), RANGE_BODY[:128])
        response = self.get("/range-ignore.mp4", {"Range": "bytes=0-127"})
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), RANGE_BODY)

    def test_hls_binary_ranges_and_shared_key(self):
        for leaf, source in [("video.bin", VIDEO_BODY), ("audio.bin", AUDIO_BODY)]:
            response = self.get(f"/hls/{leaf}", {"Range": "bytes=32-95"})
            self.assertEqual(response.status, 206)
            self.assertEqual(response.read(), source[32:96])
        self.assertEqual(self.get("/hls/key.key").read(), KEY_BODY)
        self.assertEqual(self.get("/hls-bad-key/key.key").read(), KEY_BODY[:7])
        self.assertIn('#EXT-X-BYTERANGE:64\n', media_playlist(audio=True))
        self.assertIn('BYTERANGE="32@0"', media_playlist())

    def test_audio_selection_fixtures_and_legacy_shape(self):
        default = master_playlist("hls")
        self.assertLess(default.index("Alternative"), default.index("中文, Main"))
        self.assertIn("DEFAULT=YES", default)
        self.assertIn('URI="missing.m3u8"', master_playlist("hls-fallback"))
        self.assertIn("DEFAULT=NO,AUTOSELECT=NO", master_playlist("hls-autoselect"))
        inband = master_playlist("hls-inband").split('NAME="Main",', 1)[1].splitlines()[0]
        self.assertNotIn("URI=", inband)
        self.assertIn("video-0.ts", media_playlist(legacy=True))
        response = self.get("/hls-fallback/missing.m3u8")
        self.assertEqual(response.status, 404)
        response.read()
        self.assertIn(b"SAMPLE-AES", self.get("/hls-bad-audio/audio.m3u8").read())

    def test_hold_release_and_shutdown_cleanup(self):
        self.server.state.configure({"hold": ["/plain-cancel.mp4"]})
        response = self.get("/plain-cancel.mp4")
        self.assertEqual(response.read(1024), FILE_BODY[:1024])
        self.server.state.configure({"release": ["/plain-cancel.mp4"]})
        self.assertEqual(response.read(), FILE_BODY[1024:])
        self.assertEqual(self.server.state.held, {})

    def test_source_headers_are_required(self):
        self.connection.request("GET", "/hls/master.m3u8")
        response = self.connection.getresponse()
        self.assertEqual(response.status, 403)
        response.read()


if __name__ == "__main__":
    unittest.main()
