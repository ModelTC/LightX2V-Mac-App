import Foundation

package struct ModelDownloadManifest: Decodable {
    package struct Weight: Decodable {
        let size: Int64
        let sha256: String

        package init(size: Int64, sha256: String) {
            self.size = size
            self.sha256 = sha256
        }

        var isValid: Bool {
            size > 0 && sha256.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil
        }
    }

    let revision: String
    let weights: [String: Weight]

    package init(revision: String, weights: [String: Weight]) {
        self.revision = revision
        self.weights = weights
    }

    var hasPinnedRevision: Bool {
        revision.range(of: #"\A[a-f0-9]{40}\z"#, options: .regularExpression) != nil
    }

    static func resolve(source: ModelDownloadSource, repository: String, paths: [String],
                        python: String, shell: String, workspace: WorkspaceLayout) async throws -> ModelDownloadManifest? {
        let prefix = "LIGHTX2V_MODEL_MANIFEST:"
        do {
            let result = try await SetupCommand.run(shell, arguments: [
                "-lic", #"exec "$@""#, "lightx2v-model-manifest", python, "-c", probe, source.rawValue, repository,
            ] + paths, workspace: workspace, timeout: 15, useWorkspaceEnvironment: false)
            guard result.status == 0,
                  let line = result.output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(prefix) }),
                  let manifest = try? JSONDecoder().decode(Self.self, from: Data(line.dropFirst(prefix.count).utf8)),
                  manifest.hasPinnedRevision else { return nil }
            return manifest
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Older clients, unavailable metadata and private mirrors can still use the normal downloader.
            return nil
        }
    }

    private static let probe = #"""
import json
import re
import sys

source, repository, *paths = sys.argv[1:]
if source == "huggingFace":
    from huggingface_hub import HfApi

    api = HfApi()
    revision = api.model_info(repository).sha
    if not re.fullmatch(r"[0-9a-f]{40}", revision or ""):
        sys.exit(0)
    weights = {
        file.path: {"size": file.size, "sha256": file.lfs.sha256}
        for file in api.get_paths_info(repository, paths, revision=revision)
        if getattr(file, "lfs", None)
    }
elif source == "modelScope":
    from modelscope_hub import HubApi
    from urllib.parse import urlencode
    from urllib.request import urlopen

    endpoint = HubApi().resolve_endpoint_for_read(repository, repo_type="model").rstrip("/")

    def tree(revision):
        query = urlencode({"Revision": revision, "Recursive": "true"})
        with urlopen(f"{endpoint}/api/v1/models/{repository}/repo/files?{query}", timeout=6) as response:
            result = json.load(response)
        if result.get("Code") != 200:
            raise ValueError("ModelScope file listing unavailable")
        return result["Data"]

    def head_commit(snapshot):
        # The file listing can omit the full head ID. In that case match the
        # reported short ID against full last-change IDs from the same tree.
        head = snapshot.get("LatestCommitter") or {}
        full = head.get("Id") or ""
        if re.fullmatch(r"[0-9a-f]{40}", full):
            return full
        short = head.get("ShortId") or ""
        if not re.fullmatch(r"[0-9a-f]{8,39}", short):
            return None
        matching = {
            file["Revision"] for file in snapshot["Files"]
            if re.fullmatch(r"[0-9a-f]{40}", file.get("Revision") or "") and file["Revision"].startswith(short)
        }
        return matching.pop() if len(matching) == 1 else None

    revision = head_commit(tree("master"))
    if not revision:
        sys.exit(0)
    pinned = tree(revision)
    if head_commit(pinned) != revision:
        sys.exit(0)
    weights = {
        file["Path"]: {"size": file["Size"], "sha256": file["Sha256"]}
        for file in pinned["Files"] if file.get("Path") in paths and file.get("Sha256")
    }
else:
    sys.exit(0)
print("LIGHTX2V_MODEL_MANIFEST:" + json.dumps({"revision": revision, "weights": weights}))
"""#
}
