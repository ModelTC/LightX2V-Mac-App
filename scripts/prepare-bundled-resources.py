#!/usr/bin/env python3
"""Fetch pinned build resources; the distributed APP still works offline."""
import gzip
import tarfile
import shutil
import posixpath
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


def prune_source(archive, output, entry):
    root_name = entry['archive_root']
    with tempfile.TemporaryDirectory(prefix='lightx2v-source-') as folder:
        folder = Path(folder)
        with tarfile.open(archive, 'r:gz') as source:
            for member in source.getmembers():
                parts = member.name.split('/')
                if member.name.startswith('/') or '..' in parts or parts[0] != root_name:
                    raise ValueError('Unsafe source archive path')
                if not (member.isfile() or member.isdir() or member.issym()):
                    raise ValueError('Unsupported source archive entry')
                if member.issym():
                    target = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), member.linkname))
                    if member.linkname.startswith('/') or target.split('/')[0] != root_name:
                        raise ValueError('Unsafe source archive link')
            if hasattr(tarfile, 'data_filter'):
                source.extractall(folder, filter='fully_trusted')
            else:
                source.extractall(folder)
        root = folder / root_name
        for name in entry['prune']:
            if Path(name).name != name:
                raise ValueError('Invalid pruned directory')
            path = root / name
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            elif path.exists() or path.is_symlink():
                path.unlink()
        def normalized(member):
            member.uid = member.gid = member.mtime = 0
            member.uname = member.gname = ''
            member.pax_headers = {}
            return member
        # Fixed timestamps, ownership and entry order yield the same checksum on CI and macOS.
        with output.open('wb') as stream, gzip.GzipFile(filename='', mode='wb', fileobj=stream, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as target:
                for path in [root] + sorted(root.rglob('*')):
                    target.add(path, arcname=str(path.relative_to(folder)), recursive=False, filter=normalized)


def prepare(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    for name, entry in manifest.items():
        if Path(name).name != name or not name.endswith('.tar.gz'):
            raise ValueError('Invalid bundled archive filename')
        destination = directory / name
        expected = entry.get('bundle_sha256', entry['sha256'])
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
                if digest(temporary) != entry['sha256']:
                    raise ValueError('Archive SHA-256 mismatch: ' + name)
                if entry.get('prune'):
                    processed = temporary.with_suffix('.pruned')
                    try:
                        prune_source(temporary, processed, entry)
                        if digest(processed) != expected:
                            raise ValueError('Pruned archive SHA-256 mismatch: ' + name)
                        os.replace(processed, destination)
                    finally:
                        processed.unlink(missing_ok=True)
                else:
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
