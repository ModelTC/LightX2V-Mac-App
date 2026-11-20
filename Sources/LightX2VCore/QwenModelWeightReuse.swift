import Darwin
import Foundation

package enum QwenModelWeightReuse {
    package static let sharedPaths = ["text_encoder/model.safetensors", "vae/diffusion_pytorch_model.safetensors"]

    private static func sibling(of resource: ModelResource) -> ModelResource? {
        switch resource {
        case .turbo: return .turboInt8
        case .turboInt8: return .turbo
        case .t2i, .i2i: return nil
        }
    }

    static func candidates(_ resource: ModelResource, in workspace: WorkspaceLayout) -> [String] {
        guard let sibling = sibling(of: resource) else { return [] }
        let preparedWorkspace = WorkspaceLayout(workspace.root.path)
        let source = sibling.destination(in: preparedWorkspace)
        let destination = resource.destination(in: preparedWorkspace)
        return sharedPaths.filter { path in
            let existing = source.appendingPathComponent(path)
            let target = destination.appendingPathComponent(path)
            guard let info = fileInfo(existing), info.st_size > 0 else { return false }
            guard let targetInfo = fileInfo(target) else { return true }
            guard info.st_dev == targetInfo.st_dev, info.st_ino != targetInfo.st_ino else { return false }
            if let stream = cloneID(existing), stream == cloneID(target) { return false }
            return true
        }
    }

    package static func prepare(_ resource: ModelResource, in workspace: WorkspaceLayout,
                                manifest: ModelDownloadManifest?) throws -> Bool {
        guard let manifest, manifest.hasPinnedRevision, let sibling = sibling(of: resource) else { return false }
        // Foundation can only resolve system path aliases once the workspace exists.
        let preparedWorkspace = WorkspaceLayout(workspace.root.path)
        let source = sibling.destination(in: preparedWorkspace)
        let destination = resource.destination(in: preparedWorkspace)
        var reused = false
        for path in sharedPaths {
            try Task.checkCancellation()
            guard let weight = manifest.weights[path], weight.isValid else { continue }
            do {
                if try reuse(weight, from: source.appendingPathComponent(path), to: destination.appendingPathComponent(path),
                             in: destination) { reused = true }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ReplacementError {
                throw error
            } catch {
                // Reuse is optional. A clone or validation failure leaves the CLI in charge.
                continue
            }
        }
        return reused
    }

    private struct ReplacementError: LocalizedError {
        let preservedFile: URL
        var errorDescription: String? {
            L10n.english("Unable to restore the original model weight. The original file is preserved at %@.",
                         [String(describing: preservedFile.path)])
        }
    }

    private static func reuse(_ weight: ModelDownloadManifest.Weight, from source: URL, to target: URL,
                              in destination: URL) throws -> Bool {
        guard source.resolvingSymlinksInPath().path == source.path,
              target.resolvingSymlinksInPath().path == target.path,
              let sourceInfo = fileInfo(source), sourceInfo.st_size == weight.size else { return false }
        let existing = fileInfo(target)
        if let existing {
            guard existing.st_size == weight.size, existing.st_nlink == 1,
                  existing.st_dev == sourceInfo.st_dev, existing.st_ino != sourceInfo.st_ino else { return false }
            if let stream = cloneID(source), stream == cloneID(target) { return false }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard destination.resolvingSymlinksInPath().path == destination.path else { return false }
        let temporary = destination.appendingPathComponent(".lightx2v-clone-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = temporary.appendingPathComponent(target.lastPathComponent)
        var preserveOriginal = false
        defer { if !preserveOriginal { try? fm.removeItem(at: temporary) } }

        guard clonefile(source.path, staged.path, UInt32(CLONE_NOFOLLOW)) == 0,
              fileInfo(staged)?.st_size == weight.size, try PyTorchEnvironmentInstaller.digest(staged) == weight.sha256 else { return false }
        try Task.checkCancellation()

        guard let existing else {
            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // Exclusive rename leaves a file installed by a concurrent download untouched.
            return renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0
        }
        guard try PyTorchEnvironmentInstaller.digest(target) == weight.sha256,
              copyfile(target.path, staged.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0,
              let current = fileInfo(target), sameFile(existing, current),
              current.st_ctimespec.tv_sec == existing.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == existing.st_ctimespec.tv_nsec else { return false }
        try Task.checkCancellation()
        let swap = UInt32(RENAME_SWAP)
        guard renamex_np(staged.path, target.path, swap) == 0 else { return false }
        // Keep the previous file until we verify that the swap displaced the file we checked.
        if let displaced = fileInfo(staged), sameFile(existing, displaced) { return true }
        if renamex_np(staged.path, target.path, swap) != 0 {
            preserveOriginal = true
            throw ReplacementError(preservedFile: staged)
        }
        return false
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
