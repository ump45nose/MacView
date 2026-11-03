import Foundation
import MVArchive
import MVCache
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVReading
import MVSettings
import MVTestSupport
import Synchronization

final class ReadingFixture {
    static let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory: URL
    let registry: FileSourceRegistry
    let directories: DirectoryCache
    let metadata: MetadataIndex

    init() throws {
        directory = Self.workspace.appending(path: "build/stage3-work/reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = try CacheIndex(databaseURL: directory.appending(path: "index.sqlite"))
        directories = DirectoryCache(index: index)
        metadata = MetadataIndex(index: index)
        registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
        registry.register(try ArchiveProvider(fileSystem: registry.fileSystem, extractDirectory: directory.appending(path: "extract")))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func mockPipeline(_ nodes: [MockNode]) -> TracingPipeline {
        var nodes = nodes
        for component in directory.pathComponents.dropFirst().reversed() { nodes = [.directory(component, nodes)] }
        let environment = MockEnvironment(MockOptions(tree: MockTree(root: .local, nodes: nodes), timing: .instant))
        return TracingPipeline(base: MockImagePipeline(environment: environment))
    }

    func loader(_ pipeline: any ImagePipeline) -> FileBookLoader {
        FileBookLoader(sources: registry, directories: directories, metadata: metadata, pipeline: pipeline)
    }

    func location(_ url: URL) async throws -> Location { try await registry.location(for: url) }

    func pageDirectory(_ name: String, names: [String]) throws -> URL {
        let result = directory.appending(path: name)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.linkItem(at: Self.workspace.appending(path: "Fixtures/image/size/64x64.png"), to: result.appending(path: name))
        }
        return result
    }
}

/// 消费方测试在既有 Mock 外记录调用，不改变生产接口。
final class TracingPipeline: ImagePipeline {
    let base: MockImagePipeline
    private let probes = Mutex<[Location]>([])
    init(base: MockImagePipeline) { self.base = base }
    var metadataOrder: [Location] { probes.withLock { $0 } }
    func metadata(for identity: ContentIdentity, priority: IOPriority) async throws -> ImageMetadata {
        probes.withLock { $0.append(identity.location) }
        return try await base.metadata(for: identity, priority: priority)
    }
    func thumbnail(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage { try await base.thumbnail(for: identity, maxPixel: maxPixel, priority: priority) }
    func thumbnails(for identities: [ContentIdentity], maxPixel: Int, priority: IOPriority) -> AsyncStream<(ContentIdentity, Result<RenderedImage, any Error>)> { base.thumbnails(for: identities, maxPixel: maxPixel, priority: priority) }
    func image(for identity: ContentIdentity, target: DisplayTarget, allowOriginal: Bool, priority: IOPriority) -> AsyncThrowingStream<RenderedImage, any Error> { base.image(for: identity, target: target, allowOriginal: allowOriginal, priority: priority) }
    func tiledSource(for identity: ContentIdentity) async throws -> any TiledImageSource { try await base.tiledSource(for: identity) }
    func animatedFrames(for identity: ContentIdentity, target: DisplayTarget) async throws -> any AnimatedFrameSource { try await base.animatedFrames(for: identity, target: target) }
    func videoPoster(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage { try await base.videoPoster(for: identity, maxPixel: maxPixel, priority: priority) }
    func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID) { base.setPrefetchPlan(plan, session: session) }
    func cancelAll(session: SessionID) { base.cancelAll(session: session) }
}

struct EventLoader: BookLoader {
    let stream: AsyncThrowingStream<BookLoadEvent, any Error>
    func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> { stream }
}

func pages(in book: Location, count: Int) -> [Page] {
    (0..<count).map { index in
        let location = book.appending(String(format: "%03d.jpg", index + 1))
        return Page(entry: Entry(identity: ContentIdentity(location: location, size: Int64(index + 1), modificationNanos: Int64(index)), name: location.name, kind: .image))
    }
}

func loadedPages(_ loader: any BookLoader, book: Location, settings: ResolvedBookSettings = .default, at page: Location? = nil) async throws -> [Page] {
    var result: [Page] = []
    for try await event in loader.load(book, settings: settings, startingAt: page) {
        switch event {
        case let .appended(pages): result.append(contentsOf: pages)
        case let .sorted(pages): result = pages
        case let .metadata(values):
            for index in result.indices { if let value = values[result[index].id] { result[index].metadata = value } }
        }
    }
    return result
}
