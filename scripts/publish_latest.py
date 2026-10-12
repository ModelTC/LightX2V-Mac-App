#!/usr/bin/env python3
"""Maintain one non-expiring APP per release channel; called under workflow concurrency control."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ASSET_NAME = "LightX2V-APP-macOS-arm64.zip"
PREFIX = "LightX2V-APP-macOS-arm64-"


class GitHub:
    def __init__(self, repository, token):
        self.repository = repository
        self.token = token

    def _request(self, method, host, path, data=None, content_type="application/json", missing_ok=False):
        request = urllib.request.Request(
            f"https://{host}/repos/{self.repository}/{path}", data=data, method=method,
            headers={"Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28", "Content-Type": content_type})
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            if error.code == 404 and missing_ok:
                return None
            raise

    def api(self, method, path, payload=None, missing_ok=False):
        data = json.dumps(payload).encode() if payload is not None else None
        return self._request(method, "api.github.com", path, data, missing_ok=missing_ok)

    def upload(self, release_id, name, data):
        path = f"releases/{release_id}/assets?" + urllib.parse.urlencode({"name": name})
        return self._request("POST", "uploads.github.com", path, data, "application/zip")


def list_all(client, path, key=None):
    items = []
    for page in range(1, 1001):
        response = client.api("GET", f"{path}?per_page=100&page={page}")
        batch = response[key] if key else response
        items.extend(batch)
        if len(batch) < 100:
            return items
    raise RuntimeError("Too many results; refusing incomplete cleanup")


def publish(client, archive, sha, run_number, run_id, attempt, tag="latest"):
    if tag not in {"latest", "stable"}:
        raise ValueError("Unknown release channel")
    title = "Latest build" if tag == "latest" else "Stable"
    blob = archive.read_bytes()
    digest = hashlib.sha256(blob).hexdigest()
    release = client.api("GET", f"releases/tags/{tag}", missing_ok=True)
    old = None
    if release:
        if release.get("immutable"):
            raise RuntimeError("The release is immutable and cannot be replaced")
        old = next((a for a in release["assets"] if a["name"] == ASSET_NAME), None)
        previous_run = re.search(r"lightx2v-run:(\d+)", (old or {}).get("label") or "")
        if tag == "latest" and previous_run and int(previous_run[1]) > run_number:
            print("A newer successful build is already published; leaving it unchanged.")
            return False
    else:
        release = client.api("POST", "releases", {
            "tag_name": tag, "target_commitish": sha, "draft": True,
            "name": f"LightX2V APP · {title}", "body": "Preparing the first build."})

    # Stage and verify the new upload before changing the working download.
    staged = client.upload(release["id"], f"{PREFIX}{run_id}-{attempt}.zip", blob)
    if (staged.get("state") != "uploaded" or staged.get("size") != len(blob)
            or staged.get("digest") != "sha256:" + digest):
        raise RuntimeError("Uploaded asset verification failed; previous download retained")

    old_path = f"releases/assets/{old['id']}" if old else None
    if old:
        client.api("PATCH", old_path, {"name": f"{PREFIX}backup-{old['id']}.zip"})
    try:
        client.api("PATCH", f"releases/assets/{staged['id']}", {
            "name": ASSET_NAME, "label": f"lightx2v-run:{run_number}; commit:{sha}"})
    except Exception:
        # Keep the old asset recoverable if promotion fails, rather than deleting it first.
        if old:
            client.api("PATCH", old_path, {"name": ASSET_NAME})
        raise

    ref = client.api("GET", f"git/ref/tags/{tag}", missing_ok=True)
    if ref:
        client.api("PATCH", f"git/refs/tags/{tag}", {"sha": sha, "force": True})
    else:
        client.api("POST", "git/refs", {"ref": f"refs/tags/{tag}", "sha": sha})
    url = f"https://github.com/{client.repository}"
    retention = ("Updated after every successful build; only one Latest APP is kept."
                 if tag == "latest" else "Updated only by manual promotion; only one Stable APP is kept.")
    notes = (
        f"[Download {tag.title()} APP]({url}/releases/download/{tag}/{ASSET_NAME})\n\n"
        f"{retention} Downloads do not expire automatically.\n\n"
        f"- Commit: `{sha}`\n- [Publication workflow]({url}/actions/runs/{run_id})\n"
        "- Apple Silicon / macOS 14+\n- Ad-hoc signed; not notarized\n"
        "- Requires local LightX2V source, model weights and a Python inference environment\n\n"
        f"SHA-256:\n```text\n{digest}  {ASSET_NAME}\n```\n")
    client.api("PATCH", f"releases/{release['id']}", {
        "name": f"LightX2V APP · {title}", "target_commitish": sha,
        "body": notes, "draft": False, "prerelease": False, "make_latest": "true" if tag == "latest" else "false"})

    # Only retire APP assets managed by this workflow, after successful publication.
    assets = list_all(client, f"releases/{release['id']}/assets")
    for asset in assets:
        if asset["id"] != staged["id"] and asset["name"].startswith(PREFIX) and asset["name"].endswith(".zip"):
            client.api("DELETE", f"releases/assets/{asset['id']}")
    # Migrate away from the former 30-day Actions packages; retain logs and unrelated artifacts.
    artifacts = list_all(client, "actions/artifacts", "artifacts") if tag == "latest" else []
    for artifact in artifacts:
        if re.fullmatch(r"LightX2V-APP-macOS-arm64(?:-[0-9a-f]{7,40})?\.zip", artifact["name"]):
            client.api("DELETE", f"actions/artifacts/{artifact['id']}")
    print(f"Published {url}/releases/download/{tag}/{ASSET_NAME}\nSHA-256: {digest}")
    return True


def record_download_commit(client, tag, sha):
    """Update only the published channel row, with optimistic file revision checks."""
    readme = client.api("GET", "contents/README.md?ref=main")
    content = base64.b64decode(readme["content"]).decode("utf-8")
    pattern = re.compile(rf"^(\| {tag.title()} \| [^\n]*? \| )[^\n]*?( \| [^\n]* \|)$", re.MULTILINE)
    link = f"[`{sha[:7]}`](https://github.com/{client.repository}/commit/{sha})"
    updated, count = pattern.subn(lambda match: match[1] + link + match[2], content)
    if count != 1:
        raise RuntimeError("Download channel row missing from README")
    if updated != content:
        client.api("PUT", "contents/README.md", {
            "message": f"docs: record {tag.title()} APP commit {sha[:7]}", "branch": "main",
            "sha": readme["sha"], "content": base64.b64encode(updated.encode("utf-8")).decode("ascii")})


if __name__ == "__main__":
    try:
        client = GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_TOKEN"])
        if publish(client, Path(sys.argv[1]), os.environ["GITHUB_SHA"], int(os.environ["GITHUB_RUN_NUMBER"]),
                   os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]):
            record_download_commit(client, "latest", os.environ["GITHUB_SHA"])
    except urllib.error.HTTPError as error:
        print(f"GitHub API error {error.code}: {error.read().decode(errors='replace')}", file=sys.stderr)
        sys.exit(1)
