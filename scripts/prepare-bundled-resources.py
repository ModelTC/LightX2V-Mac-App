#!/usr/bin/env python3
"""Fetch pinned build resources; the distributed APP still works offline."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import urllib.request


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(block)
    return checksum.hexdigest()


def prepare(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    for name, entry in manifest.items():
        if Path(name).name != name or not name.endswith('.tar.gz'):
            raise ValueError('Invalid bundled archive filename')
        destination = directory / name
        expected = entry['sha256']
        if destination.is_file() and digest(destination) == expected:
            print('Using verified cached archive: ' + name, flush=True)
            continue
        for attempt in range(3):
            temporary = None
            try:
                print('Downloading pinned archive: ' + name, flush=True)
                request = urllib.request.Request(entry['url'], headers={'User-Agent': 'LightX2V-APP-build'})
                with tempfile.NamedTemporaryFile(dir=directory, prefix='.download-', delete=False) as output:
                    temporary = Path(output.name)
                    with urllib.request.urlopen(request, timeout=60) as response:
                        while block := response.read(1024 * 1024):
                            output.write(block)
                if digest(temporary) != expected:
                    raise ValueError('Archive SHA-256 mismatch: ' + name)
                os.replace(temporary, destination)
                break
            except OSError:
                if attempt == 2:
                    raise
                time.sleep(2 * (attempt + 1))
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
    # Keep only the versions pinned by this manifest in the packaged resource folder.
    for path in directory.glob('*.tar.gz'):
        if path.name not in manifest:
            path.unlink()


if __name__ == '__main__':
    prepare(Path(__file__).resolve().parents[1] / 'Sources/LightX2VCore/Resources/Bundled')
