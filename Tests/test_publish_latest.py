"""Exercise release replacement and failure recovery without contacting GitHub."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/publish_latest.py"
spec = importlib.util.spec_from_file_location("publish_latest", SCRIPT)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class FakeGitHub:
    repository = "example/app"

    def __init__(self, existing=True, tag="latest"):
        self.tag = tag
        self.requests = []
        self.release = {"id": 1, "tag_name": tag, "draft": False} if existing else None
        self.assets = {8: {"id": 8, "name": publisher.ASSET_NAME, "label": "lightx2v-run:5; commit:old"}} if existing else {}
        self.assets[7] = {"id": 7, "name": "unrelated.txt"}
        self.artifacts = {20: {"id": 20, "name": "LightX2V-APP-macOS-arm64-123abcd.zip"},
                          21: {"id": 21, "name": "unrelated-test-report"}}
        self.ref = {"object": {"sha": "old"}} if existing else None
        self.fail_upload = False
        self.fail_promotion = False
        self.bad_digest = False
        self.upload_count = 0

    def api(self, method, path, payload=None, missing_ok=False):
        self.requests.append((method, path))
        route = path.split("?")[0]
        if method == "GET":
            if route == f"releases/tags/{self.tag}":
                return {**self.release, "assets": copy.deepcopy(list(self.assets.values()))} if self.release else None
            if route == "releases/1/assets": return copy.deepcopy(list(self.assets.values()))
            if route == "actions/artifacts": return {"artifacts": copy.deepcopy(list(self.artifacts.values()))}
            if route == f"git/ref/tags/{self.tag}": return copy.deepcopy(self.ref)
        if method == "POST" and route == "releases":
            self.release = {"id": 1, **payload}
            return copy.deepcopy(self.release)
        if route.startswith("releases/assets/"):
            asset_id = int(route.split("/")[-1])
            if method == "DELETE": del self.assets[asset_id]; return None
            if method == "PATCH":
                if asset_id == 9 and payload.get("name") == publisher.ASSET_NAME and self.fail_promotion:
                    raise RuntimeError("Promotion failed")
                self.assets[asset_id].update(payload)
                return copy.deepcopy(self.assets[asset_id])
        if method == "PATCH" and route == "releases/1":
            self.release.update(payload)
            return copy.deepcopy(self.release)
        if method in ("PATCH", "POST") and route.startswith("git/refs"):
            self.ref = {"object": {"sha": payload["sha"]}}
            return copy.deepcopy(self.ref)
        if method == "DELETE" and route.startswith("actions/artifacts/"):
            del self.artifacts[int(route.split("/")[-1])]
            return None
        raise AssertionError((method, route, payload))

    def upload(self, release_id, name, data):
        self.upload_count += 1
        if self.fail_upload: raise RuntimeError("Upload failed")
        self.assets[9] = {"id": 9, "name": name, "state": "uploaded", "size": len(data),
                          "digest": "sha256:" + ("invalid" if self.bad_digest else hashlib.sha256(data).hexdigest())}
        return copy.deepcopy(self.assets[9])


class LatestReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.archive = Path(self.temp.name) / publisher.ASSET_NAME
        self.archive.write_bytes(b"verified zip from package.sh")
        self.client = FakeGitHub()

    def tearDown(self):
        self.temp.cleanup()

    def publish(self, run_number=6):
        return publisher.publish(self.client, self.archive, "new-commit", run_number, "1234", "1")

    def test_success_keeps_one_app_and_preserves_unrelated_assets(self):
        self.assertTrue(self.publish())
        self.assertEqual({a["name"] for a in self.client.assets.values()}, {publisher.ASSET_NAME, "unrelated.txt"})
        self.assertEqual(set(self.client.artifacts), {21})
        self.assertEqual(self.client.ref["object"]["sha"], "new-commit")
        self.assertIn("SHA-256", self.client.release["body"])
        self.assertFalse(self.client.release["draft"])

    def test_first_release_is_published_from_draft(self):
        self.client = FakeGitHub(existing=False)
        self.assertTrue(self.publish())
        self.assertEqual(self.client.release["tag_name"], "latest")
        self.assertFalse(self.client.release["draft"])

    def test_upload_failure_preserves_old_download_and_artifact(self):
        self.client.fail_upload = True
        with self.assertRaises(RuntimeError): self.publish()
        self.assertEqual(self.client.assets[8]["name"], publisher.ASSET_NAME)
        self.assertIn(20, self.client.artifacts)
        self.assertEqual(self.client.ref["object"]["sha"], "old")

    def test_bad_upload_checksum_never_replaces_old_package(self):
        self.client.bad_digest = True
        with self.assertRaises(RuntimeError): self.publish()
        self.assertEqual(self.client.assets[8]["name"], publisher.ASSET_NAME)
        self.assertIn(20, self.client.artifacts)

    def test_failed_promotion_restores_old_download_name(self):
        self.client.fail_promotion = True
        with self.assertRaises(RuntimeError): self.publish()
        self.assertEqual(self.client.assets[8]["name"], publisher.ASSET_NAME)
        self.assertEqual(self.client.ref["object"]["sha"], "old")

    def test_rerunning_older_workflow_does_not_roll_back_latest(self):
        self.assertFalse(self.publish(run_number=4))
        self.assertEqual(self.client.upload_count, 0)
        self.assertEqual(self.client.ref["object"]["sha"], "old")


if __name__ == "__main__": unittest.main(verbosity=2)


class StableReleaseTests(unittest.TestCase):
    def test_stable_replaces_only_its_package_and_keeps_latest_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / publisher.ASSET_NAME
            archive.write_bytes(b"verified stable zip")
            client = FakeGitHub(tag="stable")
            publisher.publish(client, archive, "stable-commit", 1, "stable-run", "1", tag="stable")
            self.assertEqual({a["name"] for a in client.assets.values()}, {publisher.ASSET_NAME, "unrelated.txt"})
            self.assertEqual(set(client.artifacts), {20, 21})
            self.assertEqual(client.release["make_latest"], "false")
            self.assertEqual(client.ref["object"]["sha"], "stable-commit")
            self.assertFalse(any("latest" in path or "actions/artifacts" in path for _, path in client.requests))

    def test_failed_stable_promotion_retains_old_download(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / publisher.ASSET_NAME
            archive.write_bytes(b"stable zip")
            client = FakeGitHub(tag="stable"); client.fail_promotion = True
            with self.assertRaises(RuntimeError):
                publisher.publish(client, archive, "stable-commit", 1, "stable-run", "1", tag="stable")
            self.assertEqual(client.assets[8]["name"], publisher.ASSET_NAME)
            self.assertEqual(client.ref["object"]["sha"], "old")

class ReadmeCommitTests(unittest.TestCase):
    def test_updates_one_channel_commit_without_changing_downloads(self):
        import base64
        class ReadmeClient:
            repository = "example/app"
            def __init__(self):
                self.content = ("| Latest | [Download](latest.zip) | old-latest | Every build |\n"
                                "| Stable | [Download](stable.zip) | old-stable | Manual |\n")
            def api(self, method, path, payload=None):
                if method == "GET":
                    return {"sha": "file-revision", "content": base64.b64encode(self.content.encode()).decode()}
                self.payload = payload
                self.content = base64.b64decode(payload["content"]).decode()
        client = ReadmeClient()
        publisher.record_download_commit(client, "latest", "a" * 40)
        self.assertIn("/commit/" + "a" * 40, client.content)
        self.assertIn("| Stable | [Download](stable.zip) | old-stable | Manual |", client.content)
        publisher.record_download_commit(client, "stable", "b" * 40)
        self.assertIn("/commit/" + "a" * 40, client.content)
        self.assertIn("/commit/" + "b" * 40, client.content)
        self.assertEqual(client.payload["sha"], "file-revision")
