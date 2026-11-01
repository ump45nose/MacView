import Foundation
import MVCache
import MVFoundation
import MVIO
import MVPipeline
import MVSettings

public final class FileBookLoader: BookLoader {
    private let listing: ReadingListing
    private let metadata: MetadataIndex
    private let pipeline: any ImagePipeline

    public init(sources: any SourceRegistry, directories: DirectoryCache, metadata: MetadataIndex, pipeline: any ImagePipeline) {
        listing = ReadingListing(sources: sources, directories: directories)
        self.metadata = metadata
        self.pipeline = pipeline
    }

    public func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        AsyncThrowingStream { continuation in
            // 排序、缓存解码和枚举均不继承调用方的 MainActor。
            let task = Task.detached { [self] in
                do {
                    var cached = Snapshot()
                    let hit = try await collectCached(location, depth: 0, path: [], settings: settings, into: &cached)
                    var delivered: [ContentIdentity: ImageMetadata] = [:]
                    if hit {
                        let entries = cached.sorted(by: settings.sort)
                        continuation.yield(.sorted(entries.map { Page(entry: $0) }))
                        delivered = try await cachedMetadata(entries)
                        if !delivered.isEmpty { continuation.yield(.metadata(Dictionary(uniqueKeysWithValues: delivered.map { ($0.key.location, $0.value) }))) }
                    }
                    var fresh = Snapshot()
                    try await enumerate(location, depth: 0, path: [], settings: settings, into: &fresh, appended: !hit ? continuation : nil)
                    let entries = fresh.sorted(by: settings.sort)
                    if !hit || fresh.changed { continuation.yield(.sorted(entries.map { Page(entry: $0) })) }
                    try await probe(entries, startingAt: page, delivered: delivered, continuation: continuation)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Snapshot {
        var entries: [Entry] = []
        var paths: [Location: [Entry]] = [:]
        var changed = false

        mutating func append(_ entries: [Entry], path: [Entry]) {
            for entry in entries where ReadingListing.media(entry) {
                self.entries.append(entry)
                paths[entry.location] = path + [entry]
            }
        }

        func sorted(by sort: SortSpec) -> [Entry] {
            entries.sorted { lhs, rhs in
                let left = paths[lhs.location]!, right = paths[rhs.location]!
                for (a, b) in zip(left, right) where a.location != b.location {
                    return ReadingOrder.compare(a, b, by: sort) == .orderedAscending
                }
                return left.count < right.count
            }
        }
    }

    private func collectCached(_ container: Location, depth: Int, path: [Entry], settings: ResolvedBookSettings, into snapshot: inout Snapshot) async throws -> Bool {
        guard let cached = try await listing.directories.cachedChildren(of: container) else { return false }
        let entries = cached.entries
        snapshot.append(entries, path: path)
        if let child = ReadingListing.passage(entries) {
            _ = try await collectCached(child.location, depth: depth, path: path + [child], settings: settings, into: &snapshot)
        } else if settings.recursion.enabled && depth < settings.recursion.maxDepth {
            for child in entries where ReadingListing.book(child) {
                _ = try await collectCached(child.location, depth: depth + 1, path: path + [child], settings: settings, into: &snapshot)
            }
        }
        return true
    }

    private func enumerate(_ container: Location, depth: Int, path: [Entry], settings: ResolvedBookSettings, into snapshot: inout Snapshot, appended: AsyncThrowingStream<BookLoadEvent, any Error>.Continuation?) async throws {
        let result = try await listing.children(container, priority: .book) { entries in
            let pages = entries.filter(ReadingListing.media).map { Page(entry: $0) }
            if !pages.isEmpty { appended?.yield(.appended(pages)) }
        }
        snapshot.append(result.entries, path: path)
        snapshot.changed = snapshot.changed || result.changed
        if let child = ReadingListing.passage(result.entries) {
            try await enumerate(child.location, depth: depth, path: path + [child], settings: settings, into: &snapshot, appended: appended)
        } else if settings.recursion.enabled && depth < settings.recursion.maxDepth {
            for child in result.entries where ReadingListing.book(child) {
                try await enumerate(child.location, depth: depth + 1, path: path + [child], settings: settings, into: &snapshot, appended: appended)
            }
        }
    }

    private func cachedMetadata(_ entries: [Entry]) async throws -> [ContentIdentity: ImageMetadata] {
        var cached: [ContentIdentity: ImageMetadata] = [:]
        for container in Set(entries.compactMap { $0.location.parent }) {
            let values = try await metadata.values(in: container)
            for entry in entries where entry.location.parent == container {
                if let value = values[entry.identity.cacheKey] { cached[entry.identity] = value }
            }
        }
        return cached
    }

    private func probe(_ entries: [Entry], startingAt page: Location?, delivered: [ContentIdentity: ImageMetadata], continuation: AsyncThrowingStream<BookLoadEvent, any Error>.Continuation) async throws {
        let cached = try await cachedMetadata(entries)
        let pending = cached.filter { delivered[$0.key] != $0.value }
        if !pending.isEmpty { continuation.yield(.metadata(Dictionary(uniqueKeysWithValues: pending.map { ($0.key.location, $0.value) }))) }
        let start = page.flatMap { location in entries.firstIndex { $0.location == location } } ?? 0
        let order = entries.isEmpty ? [] : [start] + Array(0..<start) + Array((start + 1)..<entries.count)
        var batch: [Location: ImageMetadata] = [:]
        for index in order where cached[entries[index].identity] == nil {
            try Task.checkCancellation()
            let entry = entries[index]
            batch[entry.location] = try await pipeline.metadata(for: entry.identity, priority: .book)
            if batch.count == 32 { continuation.yield(.metadata(batch)); batch.removeAll(keepingCapacity: true) }
        }
        if !batch.isEmpty { continuation.yield(.metadata(batch)) }
    }
}
