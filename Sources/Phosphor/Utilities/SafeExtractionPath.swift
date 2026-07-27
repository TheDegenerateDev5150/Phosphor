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

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                      isDirectory.boolValue else {
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

        if fileManager.fileExists(atPath: destination.path) {
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
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
