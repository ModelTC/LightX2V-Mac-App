import Foundation
import CryptoKit
import LightX2VCore

extension SetupChecks {
    static func modelWeightReuseChecks(_ root: URL) throws {
        let fm = FileManager.default
        let weightPath = "text_encoder/model.safetensors"
        let original = Data(repeating: 7, count: 131_072)
        let different = Data(repeating: 8, count: original.count)
        let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let revision = String(repeating: "a", count: 40)
        let weight = ModelDownloadManifest.Weight(size: Int64(original.count), sha256: hash)
        let manifest = ModelDownloadManifest(revision: revision, weights: [weightPath: weight])

        func write(_ data: Data, to file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }

        let aliasRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("lightx2v-weight-reuse-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: aliasRoot) }
        for resource in [ModelResource.turbo, .turboInt8] {
            // Capture a fresh workspace path before mkdir, as the app does on first use.
            let base = resource == .turboInt8 ? aliasRoot : root
            let workspace = WorkspaceLayout(base.appendingPathComponent("weight reuse " + resource.rawValue).path)
            let sibling: ModelResource = resource == .turbo ? .turboInt8 : .turbo
            let destination = resource.destination(in: workspace)
            let source = sibling.destination(in: workspace).appendingPathComponent(weightPath)
            let target = destination.appendingPathComponent(weightPath)

            try write(different, to: source)
            _ = try QwenModelWeightReuse.prepare(resource, in: workspace, manifest: manifest)
            try expect(!fm.fileExists(atPath: target.path), "an incorrect source was installed")

            try write(original, to: source)
            let unpinned = ModelDownloadManifest(revision: "master", weights: [weightPath: weight])
            let noDigest = ModelDownloadManifest(revision: revision, weights: [:])
            for unusableManifest in [nil, unpinned, noDigest] {
                let reused = try QwenModelWeightReuse.prepare(resource, in: workspace, manifest: unusableManifest)
                try expect(!reused && !fm.fileExists(atPath: target.path), "unverified remote metadata seeded a weight")
            }

            _ = try QwenModelWeightReuse.prepare(resource, in: workspace, manifest: manifest)
            let clone = QwenModelWeightReuse.cloneID(source)
            try expect(clone != nil && clone == QwenModelWeightReuse.cloneID(target), "missing target was not cloned")
            let seeded = try Data(contentsOf: target)
            try expect(seeded == original, "new target has wrong data")
            try different.write(to: target)
            let untouched = try Data(contentsOf: source)
            try expect(untouched == original, "modifying the cloned weight affected its sibling")

            _ = try QwenModelWeightReuse.prepare(resource, in: workspace, manifest: manifest)
            let mismatched = try Data(contentsOf: target)
            try expect(mismatched == different, "a mismatched existing target was overwritten")

            try fm.removeItem(at: target)
            try write(original, to: target)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try expect(clone != QwenModelWeightReuse.cloneID(target), "fixture unexpectedly started as a clone")
            _ = try QwenModelWeightReuse.prepare(resource, in: workspace, manifest: manifest)
            let attributes = try fm.attributesOfItem(atPath: target.path)
            try expect(clone == QwenModelWeightReuse.cloneID(target) && attributes[.posixPermissions] as? Int == 0o600,
                       "existing duplicate was not cloned with its metadata")
            try fm.removeItem(at: source)
            let remaining = try Data(contentsOf: target)
            try expect(remaining == original, "removing either model should leave the other weight readable")
        }
        print("PASS Qwen weight reuse in both directions, clone independence, existing duplicates, mismatch and missing or unpinned remote metadata")
    }
}
