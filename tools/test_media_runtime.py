"""Regression checks for the local transport, without contacting media sites."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import zipfile
import hashlib
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch

class TransportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        root = self.root
        owner = self
        self.extraction_delay = 0
        class Downloader:
            def __init__(self, options): self.options = options
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def extract_info(self, url, download=False):
                time.sleep(owner.extraction_delay)
                return {'id': 'sample', 'title': 'Sample', 'formats': [
                    {'format_id': '140', 'url': 'https://media.example/audio', 'acodec': 'aac', 'vcodec': 'none', 'protocol': 'https',
                     'http_headers': {'User-Agent': 'extractor-agent'}}]}
            def download(self, urls):
                output = Path(self.options['outtmpl'])
                output.write_bytes(b'media')
                self.options['progress_hooks'][0]({'status': 'finished', 'downloaded_bytes': 5, 'total_bytes': 5})
        self.modules = patch.dict(sys.modules, {
            'yt_dlp': types.SimpleNamespace(YoutubeDL=Downloader, utils=types.SimpleNamespace(DownloadError=RuntimeError)),
            'certifi': types.SimpleNamespace(where=lambda: ''),
        })
        self.environment = patch.dict(os.environ, {'CAPTIONCRAFT_MEDIA_RUNTIME': str(root), 'CAPTIONCRAFT_MEDIA_TOKEN': 'test-token'})
        self.modules.start(); self.environment.start()
        spec = importlib.util.spec_from_file_location('media_transport_test', Path(__file__).parent/'media_runtime'/'main.py')
        self.runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.runtime)
        self.server = self.runtime.Server(('127.0.0.1', 0), self.runtime.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.environment.stop(); self.modules.stop(); self.directory.cleanup()

    def request(self, **fields):
        request = {'url': 'https://www.youtube.com/watch?v=jNQXAC9IVRw', 'token': 'test-token', **fields}
        with socket.create_connection(self.server.server_address, timeout=2) as connection:
            connection.sendall((json.dumps(request)+'\n').encode())
            return [json.loads(line) for line in connection.makefile()]

    def test_inspection_and_streamed_download(self):
        info = self.request(operation='inspect')[0]['result']
        self.assertEqual(info['id'], 'sample')
        events = self.request(operation='download', job='test', format='140', maxBytes=100)
        self.assertEqual(events[0]['received'], 5)
        self.assertEqual(Path(events[-1]['result']['path']).read_bytes(), b'media')

    def test_slow_extraction_sends_heartbeats_and_preserves_transport_metadata(self):
        self.runtime.HEARTBEAT_INTERVAL = .01
        self.extraction_delay = .06
        events = self.request(operation='inspect')
        self.assertEqual(events[0]['status'], 'extracting')
        result = events[-1]['result']['formats'][0]
        self.assertEqual(result['protocol'], 'https')
        self.assertEqual(result['http_headers']['User-Agent'], 'extractor-agent')

    def test_cancellation_removes_output(self):
        (self.root/'cancelled.cancel').touch()
        events = self.request(operation='download', job='cancelled', format='140', maxBytes=100)
        self.assertIn('cancelled', events[-1]['error'])
        self.assertFalse((self.root/'cancelled.media').exists())

    def test_size_limit_removes_output(self):
        events = self.request(operation='download', job='oversize', format='140', maxBytes=3)
        self.assertIn('size limit', events[-1]['error'])
        self.assertFalse((self.root/'oversize.media').exists())

    def test_transport_rejects_bad_tokens_and_unsupported_urls(self):
        self.assertEqual(self.request(token='wrong'), [])
        self.assertIn('Unsupported media URL', self.request(url='https://example.com')[0]['error'])
        self.assertIn('Invalid job', self.request(operation='download', job='../escape', format='140', maxBytes=100)[0]['error'])

    def test_media_info_bounds_lazy_entries_before_materializing_them(self):
        consumed = 0

        def entries():
            nonlocal consumed
            for index in range(24):
                consumed += 1
                yield {'id': str(index)}
            raise AssertionError('media_info consumed beyond its response bound')

        result = self.runtime.media_info({'entries': entries()})

        self.assertEqual(len(result['entries']), 24)
        self.assertEqual(consumed, 24)

class EmbeddedStartupTests(unittest.TestCase):
    def test_android_module_launch_with_bundled_dependencies(self):
        root = Path(__file__).resolve().parents[1]
        asset = root / 'assets' / 'media_runtime.zip'
        self.assertEqual(hashlib.sha256(asset.read_bytes()).hexdigest(),
                         asset.with_suffix('.zip.hash').read_text().strip())
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with zipfile.ZipFile(asset) as archive:
                archive.extractall(directory / 'dependencies')
            environment = {**os.environ,
                'CAPTIONCRAFT_MEDIA_RUNTIME': temporary,
                'CAPTIONCRAFT_MEDIA_TOKEN': 'startup-test',
                'PYTHONPATH': str(root / 'tools' / 'media_runtime') + os.pathsep +
                    str(directory / 'dependencies' / '__pypackages__')}
            # Serious Python on Android imports a module rather than running
            # it as __main__. Invoke the server explicitly, as the bridge does.
            process = subprocess.Popen([sys.executable, '-c', 'import main; main.serve()'],
                                       env=environment, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE)
            try:
                ready = directory / 'ready.json'
                deadline = time.monotonic() + 10
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue(ready.exists(), 'Embedded server did not become ready')
                port = json.loads(ready.read_text())['port']
                with socket.create_connection(('127.0.0.1', port), timeout=2) as connection:
                    connection.sendall(json.dumps({'token': 'startup-test',
                        'url': 'https://example.com', 'operation': 'inspect'}).encode() + b'\n')
                    response = json.loads(connection.makefile().readline())
                    self.assertIn('Unsupported media URL', response['error'])
            finally:
                process.terminate()
                process.communicate(timeout=5)

if __name__ == '__main__':
    unittest.main()
