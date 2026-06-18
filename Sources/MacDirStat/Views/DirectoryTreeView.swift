import SwiftUI

struct DirectoryTreeView: View {
    let root: FileNode
    @Binding var selectedNode: FileNode?
    let sizeMetric: SizeMetric
    /// Called when a folder is picked in the tree, so the map can retarget to it.
    var onDrill: (FileNode) -> Void = { _ in }

    var body: some View {
        List(selection: Binding(
            get: { selectedNode?.id },
            set: { id in
                if let id, let node = findNode(id: id, in: root) {
                    selectedNode = node
                    onDrill(node)
                }
            }
        )) {
            OutlineGroup(root.directoryChildren, id: \.id, children: \.optionalDirectoryChildren) { node in
                DirectoryRow(node: node, sizeMetric: sizeMetric)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden) // let the panel's glass show through
    }

    private func findNode(id: UInt64, in node: FileNode) -> FileNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(id: id, in: child) {
                return found
            }
        }
        return nil
    }
}

struct DirectoryRow: View {
    let node: FileNode
    let sizeMetric: SizeMetric

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(ByteFormatter.string(from: node.size(for: sizeMetric)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private extension FileNode {
    var optionalDirectoryChildren: [FileNode]? {
        let dirs = directoryChildren
        return dirs.isEmpty ? nil : dirs
    }
}
