import Darwin
import Foundation
import Synchronization

public struct PluginInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var directory: URL
    public var manifest: PluginManifest?
    public var problem: PluginProblem?

    public init(id: String, directory: URL, manifest: PluginManifest?, problem: PluginProblem?) {
        self.id = id
        self.directory = directory
        self.manifest = manifest
        self.problem = problem
    }
}

/// 扫描并监视 `Plugins/` 目录下的插件文件夹；增删改后自动重载并通过 `changes()` 通知。
public final class PluginLibrary: Sendable {
    private struct State {
        var plugins: [PluginInfo] = []
        var signatures: [String: String] = [:]
        var scanned = false
        var observers: [UUID: AsyncStream<[PluginInfo]>.Continuation] = [:]
        var directoryMonitor: (any DispatchSourceFileSystemObject)?
        var childMonitors: [any DispatchSourceFileSystemObject] = []
        var generation: UInt64 = 0
    }

    public let directory: URL
    private let queue = DispatchQueue(label: "MacView.PluginLibrary")
    private let state = Mutex(State())

    public init(directory: URL) {
        self.directory = directory
        queue.sync {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            watchRootDirectory()
        }
        queue.async { [weak self] in
            self?.scan()
        }
    }

    deinit {
        state.withLock { state in
            state.directoryMonitor?.cancel()
            for monitor in state.childMonitors { monitor.cancel() }
            for observer in state.observers.values { observer.finish() }
        }
    }

    public func plugins() -> [PluginInfo] {
        state.withLock { $0.plugins }
    }

    func signatures() -> [String: String] {
        state.withLock { $0.signatures }
    }

    public func changes() -> AsyncStream<[PluginInfo]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [PluginInfo].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { state in
            state.observers[id] = continuation
            if state.scanned { continuation.yield(state.plugins) }
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    private func watchRootDirectory() {
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        monitor.setEventHandler { [weak self] in self?.scheduleScan() }
        monitor.setCancelHandler { close(descriptor) }
        state.withLock { $0.directoryMonitor = monitor }
        monitor.resume()
    }

    private func watchChildren(_ urls: [URL]) {
        let monitors: [any DispatchSourceFileSystemObject] = urls.compactMap { url in
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            let monitor = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib],
                queue: queue
            )
            monitor.setEventHandler { [weak self] in self?.scheduleScan() }
            monitor.setCancelHandler { close(descriptor) }
            monitor.resume()
            return monitor
        }
        state.withLock { state in
            for monitor in state.childMonitors { monitor.cancel() }
            state.childMonitors = monitors
        }
    }

    private func scheduleScan() {
        let generation = state.withLock { state -> UInt64 in
            state.generation &+= 1
            return state.generation
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self, self.state.withLock({ $0.generation == generation }) else { return }
            self.scan()
        }
    }

    private func scan() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let subdirs = items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        // 先挂上子目录及其直接文件的监视，避免扫描期间的原地修改漏掉事件。
        var watched: [URL] = []
        watched.reserveCapacity(subdirs.count * 3)
        for dir in subdirs {
            watched.append(dir)
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    watched.append(file)
                }
            }
        }
        watchChildren(watched)

        var plugins: [PluginInfo] = []
        var signatures: [String: String] = [:]
        for dir in subdirs {
            let (info, sig) = Self.readPlugin(dir)
            plugins.append(info)
            signatures[info.id] = sig
        }
        plugins.sort { lhs, rhs in
            let leftName = lhs.manifest?.name ?? lhs.id
            let rightName = rhs.manifest?.name ?? rhs.id
            let order = leftName.localizedStandardCompare(rightName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }

        state.withLock { state in
            state.plugins = plugins
            state.signatures = signatures
            state.scanned = true
            for observer in state.observers.values { observer.yield(plugins) }
        }
    }

    private static func readPlugin(_ directory: URL) -> (PluginInfo, String) {
        let id = directory.lastPathComponent
        let signature = directorySignature(directory)
        guard PluginManifest.isValidPluginID(id) else {
            let problem = PluginProblem(
                file: "manifest.json",
                line: 1,
                column: 1,
                message: "插件文件夹名不合规（只能包含小写字母、数字和连字符，且不能以连字符开头）：\(id)"
            )
            return (PluginInfo(id: id, directory: directory, manifest: nil, problem: problem), signature)
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            let problem = PluginProblem(file: "manifest.json", line: 1, column: 1, message: "缺少或无法读取 manifest.json")
            return (PluginInfo(id: id, directory: directory, manifest: nil, problem: problem), signature)
        }
        switch PluginManifest.parse(data: data, file: "manifest.json") {
        case .success(let manifest):
            return (PluginInfo(id: id, directory: directory, manifest: manifest, problem: nil), signature)
        case .failure(let problem):
            return (PluginInfo(id: id, directory: directory, manifest: nil, problem: problem), signature)
        }
    }

    private static func directorySignature(_ directory: URL) -> String {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var parts: [String] = []
        for file in files {
            var st = stat()
            if stat(file.path, &st) == 0 {
                parts.append("\(file.lastPathComponent):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_ino)")
            }
        }
        return parts.joined(separator: "|")
    }
}
