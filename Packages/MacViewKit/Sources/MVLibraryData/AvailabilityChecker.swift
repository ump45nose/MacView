import Foundation
import MVCache
import MVFoundation
import MVIO

public final class AvailabilityChecker: Sendable {
    private let sources: any SourceRegistry
    private let directories: DirectoryCache?
    private let store: any LibraryStore

    public init(sources: any SourceRegistry, directories: DirectoryCache?, store: any LibraryStore) {
        self.sources = sources
        self.directories = directories
        self.store = store
    }

    public func check(_ locations: [Location]) -> AsyncStream<[Location: Availability]> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .background) { [self] in
                var immediate: [Location: Availability] = [:]
                var virtual: [Location] = []
                var groups: [Location: [Location]] = [:]
                var providers: [Location: any ContainerProvider] = [:]
                for location in Set(locations) {
                    if location.playlistID != nil { virtual.append(location); continue }
                    let container = location.parent ?? location
                    do {
                        if providers[container] == nil { providers[container] = try libraryProvider(for: container, sources: sources) }
                        groups[container, default: []].append(location)
                    } catch { immediate[location] = libraryAvailability(error, root: location.root) }
                }
                if !immediate.isEmpty { continuation.yield(immediate) }
                if !virtual.isEmpty {
                    let ids = Set(((try? await store.playlists()) ?? []).map(\.id))
                    continuation.yield(Dictionary(uniqueKeysWithValues: virtual.map {
                        ($0, ids.contains($0.playlistID!) ? .available : .missing)
                    }))
                }
                await withTaskGroup(of: Void.self) { group in
                    for (container, requested) in groups {
                        guard let provider = providers[container] else { continue }
                        group.addTask {
                            if let cached = try? await self.directories?.cachedChildren(of: container) {
                                continuation.yield(Self.results(requested, in: container, entries: cached.entries))
                            }
                            do {
                                let entries = try await libraryWithDeadline(.seconds(10)) {
                                    try await libraryChildren(of: container, provider: provider, directories: self.directories, priority: .background)
                                }
                                continuation.yield(Self.results(requested, in: container, entries: entries))
                            } catch {
                                guard !Task.isCancelled else { return }
                                let state = libraryAvailability(error, root: container.root)
                                continuation.yield(Dictionary(uniqueKeysWithValues: requested.map { ($0, state) }))
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func results(_ locations: [Location], in container: Location, entries: [Entry]) -> [Location: Availability] {
        let present = Set(entries.map(\.location))
        return Dictionary(uniqueKeysWithValues: locations.map { ($0, $0 == container || present.contains($0) ? .available : .missing) })
    }
}

/// 注册表只分派来源；文件来源的现有挂载表接口负责无卷访问的预检。
func libraryProvider(for location: Location, sources: any SourceRegistry) throws -> any ContainerProvider {
    if case .network = location.root {
        let rootProvider = try sources.provider(for: Location(root: location.root))
        if let fileSystem = rootProvider as? FileSystemProvider,
           !fileSystem.mountedNetworkRoots().contains(where: { $0.root == location.root }) {
            throw IOError.volumeUnavailable(location.root)
        }
    }
    return try sources.provider(for: location)
}

func libraryAvailability(_ error: any Error, root: Location.Root) -> Availability {
    switch error {
    case let IOError.volumeUnavailable(root), let IOError.volumeDegraded(root): .volumeUnavailable(root)
    case IOError.timeout: .volumeUnavailable(root)
    default: .missing
    }
}

func libraryChildren(of container: Location, provider: any ContainerProvider, directories: DirectoryCache?, priority: IOPriority) async throws -> [Entry] {
    var entries: [Entry] = []
    for try await batch in provider.children(of: container, priority: priority) {
        try Task.checkCancellation()
        entries.append(contentsOf: batch)
    }
    // 缓存写入失败不把实际可读的容器判成不可用。
    _ = try? await directories?.update(container, listing: DirectoryListing(entries: entries))
    return entries
}

/// 非结构化竞速保证来源不响应取消时，其他容器与消费流仍能按期结束。
func libraryWithDeadline<Value: Sendable>(_ deadline: Duration, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let stream = AsyncThrowingStream<Value, any Error> { continuation in
        let work = Task.detached {
            do {
                let value = try await operation()
                continuation.yield(value)
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        let timer = Task.detached {
            do {
                try await Task.sleep(for: deadline)
                continuation.finish(throwing: IOError.timeout)
            } catch {}
        }
        continuation.onTermination = { _ in work.cancel(); timer.cancel() }
    }
    for try await value in stream { return value }
    throw CancellationError()
}
