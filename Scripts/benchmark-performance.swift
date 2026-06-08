import Foundation

final class LinearNode {
    let name: String
    var children: [LinearNode] = []
    var files = 0
    init(_ name: String) { self.name = name }
}

final class IndexedNode {
    let name: String
    var children: [IndexedNode] = []
    private var childrenByName: [String: IndexedNode] = [:]
    var files = 0
    init(_ name: String) { self.name = name }
    func child(named name: String) -> IndexedNode? { childrenByName[name] }
    func addChild(_ child: IndexedNode) {
        children.append(child)
        childrenByName[child.name] = child
    }
}

let entries = (0..<120_000).map { i in
    "AppDomain-com.example.\(i % 500)/Library/Caches/folder\(i % 1_000)/file\(i).dat"
}

@discardableResult
func elapsed(_ label: String, _ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    let end = DispatchTime.now().uptimeNanoseconds
    let sec = Double(end - start) / 1_000_000_000
    print("\(label): \(String(format: "%.4f", sec))s")
    return sec
}

let linear = elapsed("linear child lookup") {
    let root = LinearNode("/")
    for path in entries {
        let parts = path.split(separator: "/").map(String.init)
        var current = root
        for (idx, part) in parts.enumerated() {
            if idx == parts.count - 1 {
                current.files += 1
            } else if let existing = current.children.first(where: { $0.name == part }) {
                current = existing
            } else {
                let child = LinearNode(part)
                current.children.append(child)
                current = child
            }
        }
    }
}

let indexed = elapsed("indexed child lookup") {
    let root = IndexedNode("/")
    for path in entries {
        let parts = path.split(separator: "/").map(String.init)
        var current = root
        for (idx, part) in parts.enumerated() {
            if idx == parts.count - 1 {
                current.files += 1
            } else if let existing = current.child(named: part) {
                current = existing
            } else {
                let child = IndexedNode(part)
                current.addChild(child)
                current = child
            }
        }
    }
}

print("speedup: \(String(format: "%.2fx", linear / indexed))")

if indexed >= linear {
    fputs("ERROR: indexed lookup should be faster than linear lookup\n", stderr)
    exit(1)
}
