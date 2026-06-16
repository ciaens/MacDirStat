import Foundation
import os
import Synchronization

enum ScanEvent: Sendable {
    case progress(fileCount: Int, byteCount: Int64, currentPath: String)
    case completed(root: FileNode)
    case error(String)
}

struct FileScanner: Sendable {
    let rootPath: String

    func scan() -> AsyncStream<ScanEvent> {
        let path = rootPath
        return AsyncStream { continuation in
            Task.detached {
                await performParallelScan(rootPath: path, continuation: continuation)
            }
        }
    }
}

// Thread-safe shared state for parallel scanning.
private final class ScanState: Sendable {
    let rootDevice: dev_t

    /// Absolute paths we must not descend into. These are File Provider / cloud
    /// roots (Nextcloud, Google Drive, iCloud Drive, etc.) whose contents are
    /// dataless placeholders: enumerating an un-cached subfolder blocks on a
    /// network round-trip — potentially forever if the provider is slow or
    /// offline — which would otherwise stall the whole scan. They also don't
    /// represent real local disk usage.
    let excludedPaths: Set<String>

    /// Soft cap on concurrent directory-scan tasks. Bounds the recursive
    /// fan-out so a deep/wide tree can't spawn an unbounded number of tasks.
    let parallelLimit: Int

    // Inode dedup set, sharded across many locks so the per-file/per-directory
    // dedup check doesn't serialize every core on a single mutex.
    private static let shardCount = 64
    private let shards: [OSAllocatedUnfairLock<Set<UInt64>>]

    // Progress counters. Atomics (not a lock) since they're hot and only feed
    // the progress UI — the authoritative totals come from FileNode aggregates.
    private let fileCount = Atomic<Int>(0)
    private let byteCount = Atomic<Int64>(0)
    private let activeTasks = Atomic<Int>(0)

    init(rootDevice: dev_t, excludedPaths: Set<String>, parallelLimit: Int) {
        self.rootDevice = rootDevice
        self.excludedPaths = excludedPaths
        self.parallelLimit = parallelLimit
        self.shards = (0..<Self.shardCount).map { _ in OSAllocatedUnfairLock(initialState: Set<UInt64>()) }
    }

    /// Records an inode as seen. Returns `true` if it was newly inserted (i.e.
    /// not a hardlink / firmlink duplicate we've already counted).
    func markSeen(_ inode: UInt64) -> Bool {
        shards[Int(inode % UInt64(Self.shardCount))].withLock { $0.insert(inode).inserted }
    }

    /// Adds a directory's local tallies to the running totals. Returns the new
    /// total file count (used to throttle progress events on 10k boundaries).
    func addProgress(files: Int, bytes: Int64) -> Int {
        byteCount.wrappingAdd(bytes, ordering: .relaxed)
        return fileCount.wrappingAdd(files, ordering: .relaxed).newValue
    }

    /// Soft-acquire a parallelism slot. Over-the-limit callers run inline
    /// (serially) instead of spawning a task.
    func tryAcquireSlot() -> Bool {
        if activeTasks.wrappingAdd(1, ordering: .relaxed).newValue > parallelLimit {
            activeTasks.wrappingSubtract(1, ordering: .relaxed)
            return false
        }
        return true
    }

    func releaseSlot() {
        activeTasks.wrappingSubtract(1, ordering: .relaxed)
    }

    func currentCounts() -> (files: Int, bytes: Int64) {
        (fileCount.load(ordering: .relaxed), byteCount.load(ordering: .relaxed))
    }
}

private func performParallelScan(rootPath: String, continuation: AsyncStream<ScanEvent>.Continuation) async {
    var rootStat = Darwin.stat()
    guard lstat(rootPath, &rootStat) == 0 else {
        continuation.yield(.error("Failed to stat root directory"))
        continuation.finish()
        return
    }

    let state = ScanState(
        rootDevice: rootStat.st_dev,
        excludedPaths: cloudExcludedPaths(),
        parallelLimit: max(16, ProcessInfo.processInfo.activeProcessorCount * 4)
    )

    if let root = await scanDirectory(
        atPath: rootPath,
        name: rootPath,
        state: state,
        continuation: continuation
    ) {
        root.computeAggregates()
        root.sortChildrenBySize()
        let counts = state.currentCounts()
        continuation.yield(.progress(
            fileCount: counts.files,
            byteCount: counts.bytes,
            currentPath: rootPath
        ))
        continuation.yield(.completed(root: root))
    } else {
        continuation.yield(.error("Failed to scan directory"))
    }
    continuation.finish()
}

private func scanDirectory(
    atPath path: String,
    name: String,
    state: ScanState,
    continuation: AsyncStream<ScanEvent>.Continuation
) async -> FileNode? {
    var dirStat = Darwin.stat()
    guard lstat(path, &dirStat) == 0 else { return nil }

    // Skip cross-device boundaries (equivalent to FTS_XDEV). A mounted volume's
    // root reports a different st_dev, so this stops the walk at mount points.
    guard dirStat.st_dev == state.rootDevice else { return nil }

    // Skip directories we've already scanned (firmlinks create duplicates).
    guard state.markSeen(UInt64(dirStat.st_ino)) else { return nil }

    let dirNode = FileNode(
        inode: UInt64(dirStat.st_ino),
        name: name,
        isDirectory: true,
        ownSize: Int64(dirStat.st_size),
        allocatedSize: Int64(dirStat.st_blocks) * 512,
        category: .other,
        modificationDate: Date(timeIntervalSince1970: TimeInterval(dirStat.st_mtimespec.tv_sec))
    )

    // Open a directory fd for getattrlistbulk. If we can't read it (permissions,
    // etc.) the node still exists, just with no children.
    let fd = open(path, O_RDONLY, 0)
    guard fd >= 0 else { return dirNode }
    defer { close(fd) }

    var fileChildren: [FileNode] = []
    var subdirPaths: [(path: String, name: String)] = []
    var localFiles = 0
    var localBytes: Int64 = 0

    enumerateBulk(fd: fd) { entry in
        switch entry.objType {
        case VDIR:
            let childPath = path.last == "/" ? path + entry.name : path + "/" + entry.name
            // Don't descend into cloud / File Provider roots (would block).
            if state.excludedPaths.contains(childPath) { return }
            subdirPaths.append((childPath, entry.name))

        case VREG:
            // Dedup hardlinks by inode.
            guard state.markSeen(entry.inode) else { return }
            let category = FileExtensionMap.category(for: fastPathExtension(of: entry.name))
            fileChildren.append(FileNode(
                inode: entry.inode,
                name: entry.name,
                isDirectory: false,
                ownSize: entry.dataLength,
                allocatedSize: entry.allocSize,
                category: category,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(entry.modTime))
            ))
            localFiles += 1
            localBytes += entry.dataLength

        default:
            break // symlinks, sockets, devices, etc.
        }
    }

    for file in fileChildren {
        dirNode.addChild(file)
    }

    // Publish progress on 10k-file boundaries (batched per directory).
    if localFiles > 0 {
        let newCount = state.addProgress(files: localFiles, bytes: localBytes)
        if (newCount - localFiles) / 10000 != newCount / 10000 {
            let counts = state.currentCounts()
            continuation.yield(.progress(
                fileCount: counts.files,
                byteCount: counts.bytes,
                currentPath: path
            ))
        }
    }

    // Scan subdirectories, bounding the parallel fan-out: spawn a task while
    // under the concurrency cap, otherwise recurse inline (serially).
    if subdirPaths.count == 1 {
        if let child = await scanDirectory(
            atPath: subdirPaths[0].path,
            name: subdirPaths[0].name,
            state: state,
            continuation: continuation
        ) {
            dirNode.addChild(child)
        }
    } else if !subdirPaths.isEmpty {
        await withTaskGroup(of: FileNode?.self) { group in
            var inlineChildren: [FileNode] = []
            for subdir in subdirPaths {
                if state.tryAcquireSlot() {
                    group.addTask {
                        let child = await scanDirectory(
                            atPath: subdir.path,
                            name: subdir.name,
                            state: state,
                            continuation: continuation
                        )
                        state.releaseSlot()
                        return child
                    }
                } else if let child = await scanDirectory(
                    atPath: subdir.path,
                    name: subdir.name,
                    state: state,
                    continuation: continuation
                ) {
                    inlineChildren.append(child)
                }
            }
            for await child in group {
                if let child { dirNode.addChild(child) }
            }
            for child in inlineChildren {
                dirNode.addChild(child)
            }
        }
    }

    return dirNode
}

// MARK: - getattrlistbulk enumeration

private let VREG: UInt32 = 1 // VREG from <sys/vnode.h>
private let VDIR: UInt32 = 2 // VDIR

private struct BulkEntry {
    var name: String
    var objType: UInt32
    var inode: UInt64
    var modTime: Int
    var dataLength: Int64
    var allocSize: Int64
}

/// Enumerates a directory with `getattrlistbulk`, fetching name, type, inode,
/// mtime and (for files) size + allocation in bulk — one syscall per batch
/// instead of one `fstatat` per entry. Invokes `body` for each entry.
///
/// Buffer layout per entry (validated against fstatat), with
/// ATTR_CMN_RETURNED_ATTRS requested first (a 20-byte attribute_set_t):
///   0   u_int32   entry length
///   4   …         returned attribute_set_t (20 bytes)
///   24  attrref   ATTR_CMN_NAME      (offset is relative to this field)
///   32  u_int32   ATTR_CMN_OBJTYPE
///   36  timespec  ATTR_CMN_MODTIME   (tv_sec at +36)
///   52  u_int64   ATTR_CMN_FILEID
///   60  off_t     ATTR_FILE_ALLOCSIZE   (files only)
///   68  off_t     ATTR_FILE_DATALENGTH  (files only)
private func enumerateBulk(fd: Int32, body: (BulkEntry) -> Void) {
    var attrList = attrlist()
    attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attrList.commonattr = ATTR_CMN_RETURNED_ATTRS | attrgroup_t(
        UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_FILEID)
    )
    attrList.fileattr = attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE) | UInt32(ATTR_FILE_DATALENGTH))

    let bufSize = 64 * 1024
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
    defer { buf.deallocate() }

    while true {
        let count = withUnsafeMutablePointer(to: &attrList) {
            getattrlistbulk(fd, $0, buf, bufSize, 0)
        }
        if count <= 0 { break } // 0 = done, -1 = error (skip remaining)

        var entry = buf
        for _ in 0..<count {
            let length = entry.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let nameOffset = entry.loadUnaligned(fromByteOffset: 24, as: Int32.self)
            let name = String(cString: entry.advanced(by: 24 + Int(nameOffset)).assumingMemoryBound(to: CChar.self))
            let objType = entry.loadUnaligned(fromByteOffset: 32, as: UInt32.self)

            if name != "." && name != ".." {
                let inode = entry.loadUnaligned(fromByteOffset: 52, as: UInt64.self)
                // File-only attributes are present only for regular files.
                let dataLength = objType == VREG ? entry.loadUnaligned(fromByteOffset: 68, as: Int64.self) : 0
                let allocSize = objType == VREG ? entry.loadUnaligned(fromByteOffset: 60, as: Int64.self) : 0
                let modTime = entry.loadUnaligned(fromByteOffset: 36, as: Int.self)
                body(BulkEntry(
                    name: name,
                    objType: objType,
                    inode: inode,
                    modTime: modTime,
                    dataLength: dataLength,
                    allocSize: allocSize
                ))
            }

            entry = entry.advanced(by: Int(length))
        }
    }
}

// Cloud / File Provider roots to skip. macOS mounts all third-party File
// Provider domains under ~/Library/CloudStorage, and iCloud Drive under
// ~/Library/Mobile Documents. Descending into their dataless contents blocks
// on the network, so we treat them like cross-device boundaries.
private func cloudExcludedPaths() -> Set<String> {
    let home = NSHomeDirectory()
    return [
        home + "/Library/CloudStorage",
        home + "/Library/Mobile Documents",
    ]
}

// Fast extension extraction without NSString bridging
@inline(__always)
private func fastPathExtension(of name: String) -> String {
    guard let dotIndex = name.lastIndex(of: ".") else { return "" }
    let afterDot = name.index(after: dotIndex)
    guard afterDot < name.endIndex else { return "" }
    return String(name[afterDot...])
}
