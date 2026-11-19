import Foundation
import CryptoKit
import LightX2VCore

extension SetupChecks {
    static func modelWeightReuseChecks(_ root: URL) throws {
        let fm = FileManager.default
        let weightPath = QwenModelWeightReuse.sharedWeights[0].path
        let original = Data(repeating: 7, count: 131_072)
        let different = Data(repeating: 8, count: original.count)
        let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let weight = QwenModelWeightReuse.Weight(path: weightPath, size: Int64(original.count), sha256: hash)

        func write(_ data: Data, to file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }

        for resource in [ModelResource.turbo, .turboInt8] {
            let workspace = WorkspaceLayout(root.appendingPathComponent("weight reuse " + resource.rawValue).path)
            let sibling: ModelResource = resource == .turbo ? .turboInt8 : .turbo
            let destination = resource.destination(in: workspace)
            let source = sibling.destination(in: workspace).appendingPathComponent(weightPath)
            let target = destination.appendingPathComponent(weightPath)

            try write(different, to: source)
            try QwenModelWeightReuse.prepare(resource, in: workspace, weights: [weight])
            try expect(!fm.fileExists(atPath: target.path), "an incorrect source was installed")

            try write(original, to: source)
            let metadata = destination.appendingPathComponent(".cache/huggingface/download/" + weightPath + ".metadata")
            try write(Data("stale metadata".utf8), to: metadata)
            try QwenModelWeightReuse.prepare(resource, in: workspace, weights: [weight])
            try expect(!fm.fileExists(atPath: target.path), "a missing target with stale metadata was seeded")
            try fm.removeItem(at: metadata)

            try QwenModelWeightReuse.prepare(resource, in: workspace, weights: [weight])
            let clone = QwenModelWeightReuse.cloneID(source)
            try expect(clone != nil && clone == QwenModelWeightReuse.cloneID(target), "missing target was not cloned")
            let seeded = try Data(contentsOf: target)
            try expect(seeded == original, "new target has wrong data")
            try different.write(to: target)
            let untouched = try Data(contentsOf: source)
            try expect(untouched == original, "modifying the cloned weight affected its sibling")

            try QwenModelWeightReuse.prepare(resource, in: workspace, weights: [weight])
            let mismatched = try Data(contentsOf: target)
            try expect(mismatched == different, "a mismatched existing target was overwritten")

            try fm.removeItem(at: target)
            try write(original, to: target)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try expect(clone != QwenModelWeightReuse.cloneID(target), "fixture unexpectedly started as a clone")
            try QwenModelWeightReuse.prepare(resource, in: workspace, weights: [weight])
            let attributes = try fm.attributesOfItem(atPath: target.path)
            try expect(clone == QwenModelWeightReuse.cloneID(target) && attributes[.posixPermissions] as? Int == 0o600,
                       "existing duplicate was not cloned with its metadata")
            try fm.removeItem(at: source)
            let remaining = try Data(contentsOf: target)
            try expect(remaining == original, "removing either model should leave the other weight readable")
        }
        print("PASS Qwen weight reuse in both directions, clone independence, existing duplicates, mismatch and stale metadata")
    }
}
