// MVTestSupport：Mock 与夹具加载。职责与契约见 docs/architecture.md §2、§4。
import Foundation
import MVCache
import MVCommands
import MVSearch
import MVServices

extension CoreServices {
    /// 用内存目录树和合成图搭建的一套服务，供界面开发与测试使用。各 Mock 共用同一个 MockEnvironment。
    public static func makeMock(_ options: MockOptions = MockOptions()) -> CoreServices {
        let environment = MockEnvironment(options)
        let sources = MockSourceRegistry(environment: environment)
        let library = MockLibraryStore(historyLimit: options.settings.historyLimit)
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "macview-mock-search-\(UUID().uuidString)", directoryHint: .isDirectory)
        let search: SearchCatalog?
        let indexer: FolderIndexer?
        if (try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)) != nil,
           let index = try? CacheIndex(databaseURL: cacheDirectory.appending(path: "index.sqlite")) {
            search = SearchCatalog(index: index)
            indexer = FolderIndexer(
                sources: sources,
                directories: DirectoryCache(index: index),
                metadata: MetadataIndex(index: index)
            )
        } else {
            search = nil
            indexer = nil
        }
        return CoreServices(
            sources: sources,
            pipeline: MockImagePipeline(environment: environment),
            settings: MockSettingsStore(global: options.settings),
            commands: CommandRegistry(),
            bookshelf: MockBookshelf(environment: environment),
            loader: LibraryBookLoader(files: MockBookLoader(environment: environment),
                                     playlists: MockPlaylistBookLoader(store: library, environment: environment)),
            library: library,
            search: search,
            indexer: indexer
        )
    }
}
