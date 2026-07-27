import Foundation

/// Resolves untrusted backup-manifest paths beneath an extraction root without
/// allowing traversal through absolute paths, `..`, or pre-existing symlinks.
enum SafeExtractionPath {
    enum PathError: LocalizedError {
        case unsafePath

        var errorDescription: String? {
            "Backup entry contains an unsafe extraction path"
        }
    }

    static func prepareExtractionRoot(
        selectedDirectory: URL,
        component: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard selectedDirectory.isFileURL,
              !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !(component as NSString).isAbsolutePath else {
            throw PathError.unsafePath
        }

        try fileManager.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        let lexicalBoundary = selectedDirectory.standardizedFileURL
        let resolvedBoundary = lexicalBoundary.resolvingSymlinksInPath()
        let candidate = lexicalBoundary.appendingPathComponent(component, isDirectory: true).standardizedFileURL
        guard isContained(candidate, in: lexicalBoundary) else {
            throw PathError.unsafePath
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: candidate.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw PathError.unsafePath
            }
        } else {
            try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard isContained(resolvedCandidate, in: resolvedBoundary) else {
            throw PathError.unsafePath
        }
        return resolvedCandidate
    }

    static func prepareDestination(
        root: URL,
        relativePath: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard root.isFileURL,
              !relativePath.isEmpty,
              !(relativePath as NSString).isAbsolutePath else {
            throw PathError.unsafePath
        }

        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PathError.unsafePath
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var parent = resolvedRoot

        for component in components.dropLast() {
            let candidate = parent.appendingPathComponent(component, isDirectory: true).standardizedFileURL
            guard isContained(candidate, in: resolvedRoot) else {
                throw PathError.unsafePath
            }

            // attributesOfItem does not follow symlinks, so it still reports a
            // dangling link as present. fileExists does follow, and would report
            // a dangling link as absent - see the leaf check below.
            if let attributes = try? fileManager.attributesOfItem(atPath: candidate.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw PathError.unsafePath
                }
            } else {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
            }
            parent = candidate
        }

        let destination = parent.appendingPathComponent(components[components.count - 1]).standardizedFileURL
        guard isContained(destination, in: resolvedRoot) else {
            throw PathError.unsafePath
        }

        // fileExists resolves symlinks, so a link pointing at a path that does not
        // exist yet reads as "absent" and skips this check entirely. The write then
        // follows the link and lands outside the root. attributesOfItem is lstat
        // based, so a dangling link is still seen and rejected.
        if let attributes = try? fileManager.attributesOfItem(atPath: destination.path) {
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  attributes[.type] as? FileAttributeType != .typeDirectory else {
                throw PathError.unsafePath
            }
        }

        return destination
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }
}
