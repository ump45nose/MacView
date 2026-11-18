import Foundation
import MVCache
import MVFoundation
import MVIO
import MVPipeline
import MVReading
import MVSettings

public final class PlaylistBookLoader: BookLoader {
    private let store: any LibraryStore
    private let sources: any SourceRegistry
    private let directories: DirectoryCache
    private let metadata: MetadataIndex
    private let pipeline: any ImagePipeline
    private let deadline: Duration
    private static let placeholder = ImageMetadata(pixelSize: PixelSize(width: 1000, height: 1414))

    public convenience init(store: any LibraryStore, sources: any SourceRegistry, directories: DirectoryCache, metadata: MetadataIndex, pipeline: any ImagePipeline) {
        self.init(store: store, sources: sources, directories: directories, metadata: metadata, pipeline: pipeline, deadline: .seconds(10))
    }

    init(store: any LibraryStore, sources: any SourceRegistry, directories: DirectoryCache, metadata: MetadataIndex, pipeline: any ImagePipeline, deadline: Duration) {
        self.store = store
        self.sources = sources
        self.directories = directories
        self.metadata = metadata
        self.pipeline = pipeline
        self.deadline = deadline
    }

    public func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                do {
                    guard let id = location.playlistID else { throw IOError.notFound(location) }
                    let snapshots: [Entry]
                    do { snapshots = try await store.items(of: id) }
                    catch LibraryError.notFound { throw IOError.notFound(location) }
                    continuation.yield(.sorted(snapshots.map { Page(entry: $0) }))
                    let groups = Self.groups(snapshots, startingAt: page)
                    let indices = Dictionary(uniqueKeysWithValues: snapshots.enumerated().map { ($0.element.location, $0.offset) })
                    var entries = snapshots
                    var changed: [Entry] = []
                    var values: [Location: ImageMetadata] = [:]
                    var validated = 0
                    for await event in containerEvents(groups) {
                        try Task.checkCancellation()
                        switch event {
                        case let .validated(fresh, availability):
                            for entry in fresh {
                                guard let index = indices[entry.location], entries[index] != entry else { continue }
                                entries[index] = entry
                                changed.append(entry)
                            }
                            continuation.yield(.availability(availability))
                            validated += 1
                            if validated == groups.count, !changed.isEmpty {
                                try await store.updateSnapshots(changed, in: id)
                                continuation.yield(.sorted(entries.map { Page(entry: $0, metadata: values[$0.location]) }))
                            }
                        case let .metadata(batch):
                            values.merge(batch, uniquingKeysWith: { _, new in new })
                            continuation.yield(.metadata(batch))
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Container: Sendable {
        let location: Location
        var entries: [Entry]
    }

    private enum ContainerEvent: Sendable {
        case validated([Entry], [Location: Availability])
        case metadata([Location: ImageMetadata])
    }

    private static func groups(_ entries: [Entry], startingAt page: Location?) -> [Container] {
        guard !entries.isEmpty else { return [] }
        let start = page.flatMap { location in entries.firstIndex { $0.location == location } } ?? 0
        let order = [start] + Array(0..<start) + Array((start + 1)..<entries.count)
        var groups: [Container] = [], indices: [Location: Int] = [:]
        for index in order {
            let entry = entries[index], parent = entry.location.parent ?? entry.location
            if let group = indices[parent] { groups[group].entries.append(entry) }
            else {
                indices[parent] = groups.count
                groups.append(Container(location: parent, entries: [entry]))
            }
        }
        return groups
    }

    private func containerEvents(_ containers: [Container]) -> AsyncStream<ContainerEvent> {
        AsyncStream { continuation in
            let task = Task.detached { [self] in
                await withTaskGroup(of: Void.self) { group in
                    for container in containers {
                        group.addTask { await self.inspect(container, continuation: continuation) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func inspect(_ container: Container, continuation: AsyncStream<ContainerEvent>.Continuation) async {
        let fresh: [Entry]
        do {
            fresh = try await libraryWithDeadline(deadline) { [self] in
                let provider = try libraryProvider(for: container.location, sources: sources)
                return try await libraryChildren(of: container.location, provider: provider, directories: directories, priority: .book)
            }
        } catch {
            guard !Task.isCancelled else { return }
            let state = libraryAvailability(error, root: container.location.root)
            continuation.yield(.validated([], Dictionary(uniqueKeysWithValues: container.entries.map { ($0.location, state) })))
            continuation.yield(.metadata(Self.placeholders(container.entries)))
            return
        }
        let requested = Set(container.entries.map(\.location))
        let present = Dictionary(fresh.filter { requested.contains($0.location) }.map { ($0.location, $0) }, uniquingKeysWith: { _, new in new })
        let availability = Dictionary(uniqueKeysWithValues: container.entries.map {
            ($0.location, present[$0.location] == nil ? Availability.missing : .available)
        })
        continuation.yield(.validated(Array(present.values), availability))
        do {
            let values = try await libraryWithDeadline(deadline) { [self] in
                let cached = (try? await metadata.values(in: container.location)) ?? [:]
                var values: [Location: ImageMetadata] = [:]
                for snapshot in container.entries {
                    try Task.checkCancellation()
                    guard let entry = present[snapshot.location] else {
                        values[snapshot.location] = Self.placeholder
                        continue
                    }
                    if let value = cached[entry.identity.cacheKey] { values[entry.location] = value }
                    else {
                        do { values[entry.location] = try await pipeline.metadata(for: entry.identity, priority: .book) }
                        catch IOError.timeout { throw IOError.timeout }
                        catch is CancellationError { throw CancellationError() }
                        catch { values[entry.location] = Self.placeholder }
                    }
                }
                return values
            }
            continuation.yield(.metadata(values))
        } catch {
            guard !Task.isCancelled else { return }
            continuation.yield(.metadata(Self.placeholders(container.entries)))
        }
    }

    private static func placeholders(_ entries: [Entry]) -> [Location: ImageMetadata] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.location, placeholder) })
    }
}
