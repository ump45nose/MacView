import ArgumentParser
import Foundation
import MVCache
import MVFoundation

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "搜索索引生成与查询基准。",
        subcommands: [SearchSeedCommand.self, SearchQueryCommand.self]
    )
}

private func searchScopeLocation(for rootURL: URL) -> Location {
    let standardized = rootURL.standardizedFileURL
    let components = standardized.pathComponents.filter { $0 != "/" }
    return Location(root: .local, layers: [components])
}

struct SearchSeedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed",
        abstract: "生成指定条目数的目录缓存与元数据（含中文名、评分、标签）。"
    )

    @Option(help: "要生成的总索引条目数。") var count: Int = 100_000
    @Option(help: "临时根目录（在其中创建 index.sqlite 并作为 scope）。") var root: String

    struct Report: Encodable {
        let root: String
        let database: String
        let count: Int
        let directories: Int
        let indexedCount: Int
        let elapsedMs: Double
    }

    func run() async throws {
        guard count > 0 else { throw ValidationError("count 必须为正数") }
        let start = ContinuousClock.now
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let databaseURL = rootURL.appendingPathComponent("index.sqlite")
        let index = try CacheIndex(databaseURL: databaseURL)
        let directoryCache = DirectoryCache(index: index)
        let metadataIndex = MetadataIndex(index: index)
        let scope = searchScopeLocation(for: rootURL)

        let itemsPerDirectory = 200
        let directoryCount = max(1, (count + itemsPerDirectory - 1) / (itemsPerDirectory + 1))
        let fileCount = max(0, count - directoryCount)

        let templates: [(prefix: String, ext: String, kind: EntryKind)] = [
            ("写真 2024 风景", "jpg", .image),
            ("旅行 2023 东京", "jpg", .image),
            ("人像 2024 精选", "png", .image),
            ("夜景 2025 城市", "heic", .image),
            ("自然 2024 山川", "webp", .image),
            ("ＡＢＣ １２３ ｶﾀｶﾅ", "jpg", .image),
            ("漫画 2024 合集", "zip", .archive(.zip)),
            ("短片 2024 旅拍", "mp4", .video),
        ]
        let tagPool: [[String]?] = [
            ["精选", "风景"],
            ["精选", "人像", "2024"],
            ["旅行", "东京"],
            ["夜景", "城市"],
            ["自然", "山川"],
            ["建筑", "黑白"],
            ["人像"],
            ["风景"],
            nil,
            nil,
        ]

        var directoryEntries: [Entry] = []
        directoryEntries.reserveCapacity(directoryCount)
        for dirIndex in 0..<directoryCount {
            let dirName = String(format: "相册_%04d", dirIndex)
            let dirLocation = scope.appending(dirName)
            let identity = ContentIdentity(location: dirLocation, size: 0, modificationNanos: 1_700_000_000_000_000_000 + Int64(dirIndex))
            directoryEntries.append(Entry(identity: identity, name: dirName, kind: .directory))
        }
        _ = try await directoryCache.update(scope, listing: DirectoryListing(entries: directoryEntries))

        var generated = 0
        for dirIndex in 0..<directoryCount {
            let remaining = fileCount - generated
            if remaining <= 0 { break }
            let remainingDirs = directoryCount - dirIndex
            let batchCount = (remaining + remainingDirs - 1) / remainingDirs
            let dirLocation = directoryEntries[dirIndex].location
            var entries: [Entry] = []
            entries.reserveCapacity(batchCount)
            var metadataBatch: [String: ImageMetadata] = [:]
            metadataBatch.reserveCapacity(batchCount)

            for offset in 0..<batchCount {
                let id = generated + offset
                let template = templates[id % templates.count]
                let fileName = String(format: "%@_%06d.%@", template.prefix, id, template.ext)
                let fileLocation = dirLocation.appending(fileName)
                let identity = ContentIdentity(
                    location: fileLocation,
                    size: Int64(100_000 + (id % 5_000_000)),
                    modificationNanos: 1_700_000_000_000_000_000 + Int64(id)
                )
                let entry = Entry(identity: identity, name: fileName, kind: template.kind)
                entries.append(entry)

                if template.kind == .image || template.kind == .video {
                    let ratingBucket = id % 7
                    let rating: Int? = switch ratingBucket {
                    case 0: nil
                    case 1: 0
                    case 2: 1
                    case 3: 2
                    case 4: 3
                    case 5: 4
                    default: 5
                    }
                    let tags = tagPool[id % tagPool.count]
                    if rating != nil || tags != nil {
                        metadataBatch[identity.cacheKey] = ImageMetadata(
                            pixelSize: PixelSize(width: 4000, height: 3000),
                            frameCount: 1,
                            rating: rating,
                            tags: tags
                        )
                    }
                }
            }

            _ = try await directoryCache.update(dirLocation, listing: DirectoryListing(entries: entries))
            if !metadataBatch.isEmpty {
                try await metadataIndex.store(metadataBatch, in: dirLocation)
            }
            generated += batchCount
        }

        let catalog = SearchCatalog(index: index)
        let indexed = try await catalog.indexedCount(under: scope)
        let elapsedMs = milliseconds(ContinuousClock.now - start)
        let report = Report(
            root: rootURL.path,
            database: databaseURL.path,
            count: count,
            directories: directoryCount,
            indexedCount: indexed,
            elapsedMs: elapsedMs
        )
        try JSONReport.write(report, to: nil)
    }
}

struct SearchQueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "在指定临时索引上执行搜索查询与标签建议，记录耗时与命中数。"
    )

    @Option(help: "包含 index.sqlite 的根目录。") var root: String
    @Option(help: "空白分隔的搜索关键词。") var terms: String?
    @Option(name: .long, help: "最低评分（1–5；0 表示未评分）。") var minimumRating: Int?
    @Option(name: .long, help: "标签筛选（可多次传入）。") var tag: [String] = []
    @Option(name: .long, help: "类型筛选（image/video/archive/directory，可多次传入）。") var kind: [String] = []
    @Option(name: .long, help: "标签建议前缀。") var tagPrefix: String?
    @Option(help: "返回命中上限。") var limit: Int = 5000
    @Option(name: .long, help: "标签建议上限。") var tagLimit: Int = 20
    @Flag(help: "运行 C1.7 与 C1.17 基准套件。") var suite: Bool = false
    @Option(help: "JSON 输出路径（省略时打印到标准输出）。") var output: String?

    struct QueryMeasurement: Encodable {
        let name: String
        let terms: [String]
        let minimumRating: Int?
        let tags: [String]
        let kinds: [String]
        let hitCount: Int
        let truncated: Bool
        let indexedCount: Int
        let elapsedMs: Double
        let pass: Bool
    }

    struct TagSuggestionsMeasurement: Encodable {
        let name: String
        let prefix: String
        let limit: Int
        let suggestions: [String]
        let elapsedMs: Double
        let pass: Bool
    }

    struct SuiteReport: Encodable {
        let environment: BenchEnvironment
        let indexedCount: Int
        let thresholdMs: Double
        let queries: [QueryMeasurement]
        let tagSuggestions: [TagSuggestionsMeasurement]
    }

    struct SingleReport: Encodable {
        let query: QueryMeasurement?
        let tagSuggestions: TagSuggestionsMeasurement?
    }

    func run() async throws {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let databaseURL = rootURL.appendingPathComponent("index.sqlite")
        let scope = searchScopeLocation(for: rootURL)
        let thresholdMs = 300.0

        if suite {
            let index = try CacheIndex(databaseURL: databaseURL)
            let catalog = SearchCatalog(index: index)

            // C1.7：首次查询（冷启动数据库后的第一次多词中文查询）
            let firstStart = ContinuousClock.now
            let firstResult = try await catalog.query(SearchQuery(
                terms: ["写真", "2024"],
                scope: scope,
                limit: limit
            ))
            let firstMs = milliseconds(ContinuousClock.now - firstStart)

            // C1.17：标签含“精选”加评分 >= 4 筛选
            let tagRatingStart = ContinuousClock.now
            let tagRatingResult = try await catalog.query(SearchQuery(
                terms: [],
                scope: scope,
                minimumRating: 4,
                tags: ["精选"],
                limit: limit
            ))
            let tagRatingMs = milliseconds(ContinuousClock.now - tagRatingStart)

            // C1.17：tagSuggestions（全量与带前缀）
            let allTagsStart = ContinuousClock.now
            let allTags = try await catalog.tagSuggestions(prefix: "", limit: tagLimit)
            let allTagsMs = milliseconds(ContinuousClock.now - allTagsStart)

            let prefixTagsStart = ContinuousClock.now
            let prefixTags = try await catalog.tagSuggestions(prefix: "精", limit: tagLimit)
            let prefixTagsMs = milliseconds(ContinuousClock.now - prefixTagsStart)

            let report = SuiteReport(
                environment: BenchEnvironment.collect(paths: [rootURL.path], host: nil),
                indexedCount: firstResult.indexedCount,
                thresholdMs: thresholdMs,
                queries: [
                    QueryMeasurement(
                        name: "C1.7-first-query-keywords",
                        terms: ["写真", "2024"],
                        minimumRating: nil,
                        tags: [],
                        kinds: [],
                        hitCount: firstResult.hits.count,
                        truncated: firstResult.truncated,
                        indexedCount: firstResult.indexedCount,
                        elapsedMs: firstMs,
                        pass: firstMs <= thresholdMs
                    ),
                    QueryMeasurement(
                        name: "C1.17-tag-and-rating",
                        terms: [],
                        minimumRating: 4,
                        tags: ["精选"],
                        kinds: [],
                        hitCount: tagRatingResult.hits.count,
                        truncated: tagRatingResult.truncated,
                        indexedCount: tagRatingResult.indexedCount,
                        elapsedMs: tagRatingMs,
                        pass: tagRatingMs <= thresholdMs
                    ),
                ],
                tagSuggestions: [
                    TagSuggestionsMeasurement(
                        name: "C1.17-tag-suggestions-all",
                        prefix: "",
                        limit: tagLimit,
                        suggestions: allTags,
                        elapsedMs: allTagsMs,
                        pass: allTagsMs <= thresholdMs
                    ),
                    TagSuggestionsMeasurement(
                        name: "C1.17-tag-suggestions-prefix",
                        prefix: "精",
                        limit: tagLimit,
                        suggestions: prefixTags,
                        elapsedMs: prefixTagsMs,
                        pass: prefixTagsMs <= thresholdMs
                    ),
                ]
            )
            try JSONReport.write(report, to: output)
            return
        }

        let index = try CacheIndex(databaseURL: databaseURL)
        let catalog = SearchCatalog(index: index)
        let parsedKinds = Set(kind.compactMap { SearchKind(rawValue: $0) })
        let parsedTerms = (terms ?? "").split(whereSeparator: \.isWhitespace).map(String.init)

        var queryMeasurement: QueryMeasurement?
        if terms != nil || minimumRating != nil || !tag.isEmpty || !parsedKinds.isEmpty || tagPrefix == nil {
            let start = ContinuousClock.now
            let result = try await catalog.query(SearchQuery(
                terms: parsedTerms,
                scope: scope,
                minimumRating: minimumRating,
                tags: tag,
                kinds: parsedKinds,
                limit: limit
            ))
            let elapsedMs = milliseconds(ContinuousClock.now - start)
            queryMeasurement = QueryMeasurement(
                name: "query",
                terms: parsedTerms,
                minimumRating: minimumRating,
                tags: tag,
                kinds: parsedKinds.map(\.rawValue).sorted(),
                hitCount: result.hits.count,
                truncated: result.truncated,
                indexedCount: result.indexedCount,
                elapsedMs: elapsedMs,
                pass: elapsedMs <= thresholdMs
            )
        }

        var tagMeasurement: TagSuggestionsMeasurement?
        if let tagPrefix {
            let start = ContinuousClock.now
            let suggestions = try await catalog.tagSuggestions(prefix: tagPrefix, limit: tagLimit)
            let elapsedMs = milliseconds(ContinuousClock.now - start)
            tagMeasurement = TagSuggestionsMeasurement(
                name: "tag-suggestions",
                prefix: tagPrefix,
                limit: tagLimit,
                suggestions: suggestions,
                elapsedMs: elapsedMs,
                pass: elapsedMs <= thresholdMs
            )
        }

        try JSONReport.write(SingleReport(query: queryMeasurement, tagSuggestions: tagMeasurement), to: output)
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1000.0 + Double(components.attoseconds) / 1e15
}
