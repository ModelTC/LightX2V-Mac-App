#!/usr/bin/env python3
"""Promote the existing Latest package without rebuilding or changing Latest."""
import hashlib
import os
from pathlib import Path
import re
import tempfile
import urllib.request
import zipfile

from publish_latest import ASSET_NAME, GitHub, publish


def promote(client, run_number, run_id, attempt):
    release = client.api("GET", "releases/tags/latest")
    if release.get("draft"):
        raise RuntimeError("Latest is not published")
    asset = next(a for a in release["assets"] if a["name"] == ASSET_NAME)
    match = re.search(r"commit:([0-9a-f]{40})", asset.get("label") or "")
    if not match:
        raise RuntimeError("Latest package has no verified source commit")
    sha = match[1]
    reference = client.api("GET", "git/ref/tags/latest")
    if reference["object"]["sha"] != sha:
        raise RuntimeError("Latest tag does not match its package")
    request = urllib.request.Request(asset["browser_download_url"], headers={"User-Agent": "LightX2V-stable-promotion"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    if len(data) != asset["size"] or "sha256:" + hashlib.sha256(data).hexdigest() != asset["digest"]:
        raise RuntimeError("Latest download does not match the released package digest")
    with tempfile.TemporaryDirectory(prefix="lightx2v-stable-") as directory:
        archive = Path(directory) / ASSET_NAME
        archive.write_bytes(data)
        with zipfile.ZipFile(archive) as package:
            if package.testzip() is not None or not any(".app/Contents/MacOS/" in n for n in package.namelist()):
                raise RuntimeError("Latest package is invalid")
        publish(client, archive, sha, run_number, run_id, attempt, tag="stable")


if __name__ == "__main__":
    promote(GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_TOKEN"]),
            int(os.environ["GITHUB_RUN_NUMBER"]), os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"])
