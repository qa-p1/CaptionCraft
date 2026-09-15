"""Build the platform-independent yt-dlp asset from pinned pure-Python wheels."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tools' / 'media_runtime'
OUTPUT = ROOT / 'assets' / 'media_runtime.zip'

with tempfile.TemporaryDirectory() as temporary:
    subprocess.run([sys.executable, '-m', 'pip', 'download', '--no-deps',
                    '--only-binary=:all:', '-r', str(SOURCE / 'requirements.txt'),
                    '-d', temporary], check=True)
    files = {'main.py': (SOURCE / 'main.py').read_bytes(),
             'requirements.txt': (SOURCE / 'requirements.txt').read_bytes()}
    for wheel in sorted(Path(temporary).glob('*.whl')):
        if not wheel.name.endswith('-none-any.whl'):
            raise ValueError(f'Expected a pure-Python wheel: {wheel.name}')
        with zipfile.ZipFile(wheel) as archive:
            for name in archive.namelist():
                if not name.endswith('/'):
                    files['__pypackages__/' + name] = archive.read(name)
    with zipfile.ZipFile(OUTPUT, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
OUTPUT.with_suffix('.zip.hash').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest() + '\n')
print(f'Created {OUTPUT} ({OUTPUT.stat().st_size:,} bytes)')
