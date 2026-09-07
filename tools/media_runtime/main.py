"""Local transport for yt-dlp. All website extraction belongs to yt-dlp."""
import hmac
import json
import os
from pathlib import Path
import socketserver
import time
from urllib.parse import urlparse

import certifi
import yt_dlp

os.environ['SSL_CERT_FILE'] = certifi.where()
ROOT = Path(os.environ['CAPTIONCRAFT_MEDIA_RUNTIME'])
TOKEN = os.environ['CAPTIONCRAFT_MEDIA_TOKEN']
HOSTS = {'www.instagram.com', 'www.youtube.com', 'youtube.com', 'youtu.be'}


def media_info(info):
    keys = ('id', 'title', 'uploader', 'thumbnail', 'url', 'ext', 'duration',
            'format_id', 'width', 'height', 'vcodec', 'acodec', 'http_headers',
            'filesize', 'filesize_approx', 'fps', 'abr')
    result = {k: info[k] for k in keys if k in info}
    if info.get('entries') is not None:
        result['entries'] = [media_info(e) for e in list(info['entries'])[:24] if e]
    if info.get('formats'):
        result['formats'] = [media_info(f) for f in info['formats']]
    return result


class Handler(socketserver.StreamRequestHandler):
    def send(self, value):
        self.wfile.write((json.dumps(value) + '\n').encode())
        self.wfile.flush()

    def handle(self):
        self.connection.settimeout(15)
        try:
            request = json.loads(self.rfile.readline(8192))
            if not hmac.compare_digest(str(request.get('token', '')), TOKEN):
                return
            url = request['url']
            parsed = urlparse(url)
            if parsed.scheme != 'https' or parsed.hostname not in HOSTS:
                raise ValueError('Unsupported media URL')
            options = {
                'quiet': True, 'no_warnings': True, 'socket_timeout': 10,
                'retries': 1, 'extractor_retries': 1, 'fragment_retries': 1,
                'noplaylist': True, 'playlistend': 24, 'cachedir': False,
                'nocheckcertificate': False,
            }
            operation = request.get('operation', 'inspect')
            if operation == 'inspect':
                with yt_dlp.YoutubeDL(options) as client:
                    info = client.extract_info(url, download=False)
                self.send({'result': media_info(info)})
                return
            if operation != 'download':
                raise ValueError('Unsupported operation')
            job = str(request['job'])
            if not job.replace('-', '').isalnum():
                raise ValueError('Invalid job')
            output = ROOT / (job + '.media')
            cancel = ROOT / (job + '.cancel')
            maximum = int(request['maxBytes'])
            if maximum <= 0:
                raise ValueError('Download exceeded the size limit')
            last_progress = 0.0

            def progress(event):
                nonlocal last_progress
                if cancel.exists():
                    raise yt_dlp.utils.DownloadError('Download cancelled')
                received = event.get('downloaded_bytes', 0)
                if received > maximum:
                    raise yt_dlp.utils.DownloadError('Download exceeded the size limit')
                now = time.monotonic()
                if now - last_progress > .15 or event['status'] == 'finished':
                    self.send({'received': received, 'total': event.get('total_bytes') or
                               event.get('total_bytes_estimate')})
                    last_progress = now

            options.update({'format': str(request['format']), 'outtmpl': str(output),
                            'max_filesize': maximum, 'progress_hooks': [progress],
                            'overwrites': True, 'continuedl': False})
            try:
                with yt_dlp.YoutubeDL(options) as client:
                    client.download([url])
                if not output.exists() or output.stat().st_size == 0:
                    raise ValueError('No media was downloaded')
                if output.stat().st_size > maximum:
                    raise ValueError('Download exceeded the size limit')
                if cancel.exists():
                    raise ValueError('Download cancelled')
                self.send({'result': {'path': str(output)}})
            except Exception:
                output.unlink(missing_ok=True)
                raise
            finally:
                Path(str(output) + '.part').unlink(missing_ok=True)
                cancel.unlink(missing_ok=True)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            try:
                self.send({'error': str(error)[-700:]})
            except OSError:
                pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


def serve():
    with Server(('127.0.0.1', 0), Handler) as server:
        ready = ROOT / 'ready.json'
        temporary = ROOT / 'ready.tmp'
        temporary.write_text(json.dumps({'port': server.server_address[1]}))
        temporary.replace(ready)
        server.serve_forever()


if __name__ == '__main__':
    serve()
