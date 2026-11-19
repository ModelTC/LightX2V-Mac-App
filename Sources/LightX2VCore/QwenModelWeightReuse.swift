import Darwin
import Foundation

package enum QwenModelWeightReuse {
    package struct Weight {
        package let path: String
        let size: Int64
        let sha256: String

        package init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    // These two artifacts have matching SHA-256 hashes in both official Turbo repositories.
    // The download CLI still checks the files against the selected repository revision.
    package static let sharedWeights = [
        Weight(path: "text_encoder/model.safetensors", size: 17_534_340_584,
               sha256: "a1eee8233f3063466dd3b06e857b0a2cf13a77c543908374771d51a546beb2e0"),
        Weight(path: "vae/diffusion_pytorch_model.safetensors", size: 675_508_656,
               sha256: "71879ffd5321e6d10c3c87513e2b474b1252efa7f3dec2969214a9bf06a6dd5c"),
    ]

    package static func prepare(_ resource: ModelResource, in workspace: WorkspaceLayout, weights: [Weight] = sharedWeights) throws {
        guard resource.isTurbo else { return }
        let sibling: ModelResource = resource == .turbo ? .turboInt8 : .turbo
        let source = sibling.destination(in: workspace)
        let destination = resource.destination(in: workspace)
        for weight in weights {
            try Task.checkCancellation()
            do {
                try reuse(weight, from: source, to: destination)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ReplacementError {
                throw error
            } catch {
                // Reuse is optional. A clone or validation failure leaves the CLI in charge.
                continue
            }
        }
    }

    private struct ReplacementError: LocalizedError {
        let preservedFile: URL
        var errorDescription: String? {
            L10n.english("Unable to restore the original model weight. The original file is preserved at %@.",
                         [String(describing: preservedFile.path)])
        }
    }

    private static func reuse(_ weight: Weight, from sibling: URL, to destination: URL) throws {
        let source = sibling.appendingPathComponent(weight.path)
        let target = destination.appendingPathComponent(weight.path)
        guard source.resolvingSymlinksInPath().path == source.path,
              target.resolvingSymlinksInPath().path == target.path,
              let sourceInfo = fileInfo(source), sourceInfo.st_size == weight.size else { return }
        let existing = fileInfo(target)
        if let existing {
            guard existing.st_size == weight.size, existing.st_nlink == 1,
                  existing.st_dev == sourceInfo.st_dev, existing.st_ino != sourceInfo.st_ino else { return }
            if let stream = cloneID(source), stream == cloneID(target) { return }
        } else {
            // An orphaned Hugging Face sidecar could cause its CLI to trust the cloned file
            // as a different revision without hashing it. Leave that recovery to the CLI.
            let metadata = destination.appendingPathComponent(".cache/huggingface/download/" + weight.path + ".metadata")
            var info = stat()
            guard lstat(metadata.path, &info) != 0, errno == ENOENT else { return }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard destination.resolvingSymlinksInPath().path == destination.path else { return }
        let temporary = destination.appendingPathComponent(".lightx2v-clone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = temporary.appendingPathComponent(target.lastPathComponent)
        var preserveOriginal = false
        defer { if !preserveOriginal { try? fm.removeItem(at: temporary) } }

        guard clonefile(source.path, staged.path, UInt32(CLONE_NOFOLLOW)) == 0,
              fileInfo(staged)?.st_size == weight.size, try PyTorchEnvironmentInstaller.digest(staged) == weight.sha256 else { return }
        try Task.checkCancellation()

        guard let existing else {
            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // Exclusive rename leaves a file installed by a concurrent download untouched.
            _ = renamex_np(staged.path, target.path, UInt32(RENAME_EXCL))
            return
        }
        guard try PyTorchEnvironmentInstaller.digest(target) == weight.sha256,
              copyfile(target.path, staged.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0,
              let current = fileInfo(target), sameFile(existing, current),
              current.st_ctimespec.tv_sec == existing.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == existing.st_ctimespec.tv_nsec else { return }
        try Task.checkCancellation()
        let swap = UInt32(RENAME_SWAP)
        guard renamex_np(staged.path, target.path, swap) == 0 else { return }
        // Keep the previous file until we verify that the swap displaced the file we checked.
        if let displaced = fileInfo(staged), sameFile(existing, displaced) { return }
        if renamex_np(staged.path, target.path, swap) != 0 {
            preserveOriginal = true
            throw ReplacementError(preservedFile: staged)
        }
    }

    private static func fileInfo(_ url: URL) -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return info
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    package static func cloneID(_ url: URL) -> UInt64? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.forkattr = UInt32(ATTR_CMNEXT_CLONEID)
        var result = [UInt8](repeating: 0, count: 12)
        let status = result.withUnsafeMutableBytes { bytes in
            getattrlist(url.path, &attributes, bytes.baseAddress, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        let id = result.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        return id == 0 ? nil : id
    }

}
