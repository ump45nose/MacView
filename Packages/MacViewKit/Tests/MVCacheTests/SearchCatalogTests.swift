import Foundation
import GRDB
import MVFoundation
import Testing
@testable import MVCache

private struct SearchTestDirectory {
    let url: URL
    var database: URL { url.appendingPathComponent("index.sqlite") }

    init() throws {
        url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../build/stage-1-work/search-tests/" + UUID().uuidString).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func makeEntry(
    _ name: String,
    in container: Location,
    kind: EntryKind? = nil,
    size: Int64 = 1024,
    modified: Int64 = 100
) -> Entry {
    let resolvedKind = kind ?? EntryKind(fileName: name)
    return Entry(
        identity: ContentIdentity(location: container.appending(name), size: size, modificationNanos: modified),
        name: name,
        kind: resolvedKind
    )
}

// MARK: C1.5 关键词匹配、NFKC、大小写、中日文、通配符转义

@Test func searchQueryMatchesTermsNFKCKanaAndEscapedWildcards() async throws {
    let directory = try SearchTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let directoryCache = DirectoryCache(index: index)
    let catalog = SearchCatalog(index: index)

    let root = Location(root: .local, layers: [["photos"]])
    let entries = [
        makeEntry("写真 2024 东京.jpg", in: root),
        makeEntry("写真 2023 大阪.jpg", in: root),
        makeEntry("旅行 2024 京都.jpg", in: root),
        makeEntry("ＡＢＣ１２３ ｶﾀｶﾅ.jpg", in: root),
        makeEntry("ひらがな テスト.png", in: root),
        makeEntry("折扣 100% 活动.jpg", in: root),
        makeEntry("折扣 1000 活动.jpg", in: root),
        makeEntry("photo_01.jpg", in: root),
        makeEntry("photoX01.jpg", in: root),
    ]
    _ = try await directoryCache.update(root, listing: DirectoryListing(entries: entries))

    // 多词 AND：“写真 2024” 只命中同时含两个词的名字
    let multi = try await catalog.query(SearchQuery(terms: ["写真", "2024"], scope: root))
    #expect(multi.hits.map(\.entry.name) == ["写真 2024 东京.jpg"])
    #expect(multi.indexedCount == entries.count)
    #expect(!multi.truncated)

    // 两字中文
    let zh = try await catalog.query(SearchQuery(terms: ["写真"], scope: root))
    #expect(Set(zh.hits.map(\.entry.name)) == ["写真 2024 东京.jpg", "写真 2023 大阪.jpg"])

    // 全角/半角 NFKC 与大小写
    let nfkc = try await catalog.query(SearchQuery(terms: ["abc123", "カタカナ"], scope: root))
    #expect(nfkc.hits.map(\.entry.name) == ["ＡＢＣ１２３ ｶﾀｶﾅ.jpg"])

    // 日文假名
    let kana = try await catalog.query(SearchQuery(terms: ["ひらがな", "ﾃｽﾄ"], scope: root))
    #expect(kana.hits.map(\.entry.name) == ["ひらがな テスト.png"])

    // % 和 _ 按字面匹配，不当作 SQL 通配符
    let percent = try await catalog.query(SearchQuery(terms: ["100%"], scope: root))
    #expect(percent.hits.map(\.entry.name) == ["折扣 100% 活动.jpg"])

    let underscore = try await catalog.query(SearchQuery(terms: ["photo_01"], scope: root))
    #expect(underscore.hits.map(\.entry.name) == ["photo_01.jpg"])
}

// MARK: C1.6 评分、标签、类型、scope 隔离、tagSuggestions

@Test func searchQueryFiltersRatingTagsKindsAndIsolatesSiblingScopes() async throws {
    let directory = try SearchTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let directoryCache = DirectoryCache(index: index)
    let metadataIndex = MetadataIndex(index: index)
    let catalog = SearchCatalog(index: index)

    let root = Location(root: .local, layers: [["lib"]])
    let scopeA = root.appending("a")
    let scopeAB = root.appending("ab")
    let subA = scopeA.appending("sub")

    let a1 = makeEntry("img1.jpg", in: scopeA)
    let a2 = makeEntry("img2.jpg", in: scopeA)
    let a3 = makeEntry("clip.mp4", in: scopeA)
    let a4 = makeEntry("pack.zip", in: scopeA)
    let aSub = makeEntry("sub", in: scopeA, kind: .directory)
    let aNested = makeEntry("nested.jpg", in: subA)
    let ab1 = makeEntry("img1.jpg", in: scopeAB)

    _ = try await directoryCache.update(root, listing: DirectoryListing(entries: [
        makeEntry("a", in: root, kind: .directory),
        makeEntry("ab", in: root, kind: .directory),
    ]))
    _ = try await directoryCache.update(scopeA, listing: DirectoryListing(entries: [a1, a2, a3, a4, aSub]))
    _ = try await directoryCache.update(subA, listing: DirectoryListing(entries: [aNested]))
    _ = try await directoryCache.update(scopeAB, listing: DirectoryListing(entries: [ab1]))

    let size = PixelSize(width: 100, height: 100)
    try await metadataIndex.store([
        a1.identity.cacheKey: ImageMetadata(pixelSize: size, rating: 5, tags: ["精选", "风景"]),
        a2.identity.cacheKey: ImageMetadata(pixelSize: size, rating: 3, tags: ["精选"]),
        a3.identity.cacheKey: ImageMetadata(pixelSize: size, rating: 0, tags: ["旅行"]),
    ], in: scopeA)
    try await metadataIndex.store([
        aNested.identity.cacheKey: ImageMetadata(pixelSize: size, rating: 4, tags: ["精选", "风景", "人像"]),
    ], in: subA)
    try await metadataIndex.store([
        ab1.identity.cacheKey: ImageMetadata(pixelSize: size, rating: 5, tags: ["精选", "风景"]),
    ], in: scopeAB)

    // scope 隔离：a 不混入 ab，也不把 a 自己算进 a 下已索引数
    #expect(try await catalog.indexedCount(under: scopeA) == 6)
    #expect(try await catalog.indexedCount(under: scopeAB) == 1)

    // 评分 >= 4
    let highRated = try await catalog.query(SearchQuery(scope: scopeA, minimumRating: 4))
    #expect(Set(highRated.hits.map(\.entry.location)) == [a1.location, aNested.location])
    #expect(highRated.hits.first(where: { $0.entry.location == a1.location })?.rating == 5)

    // 未评分（0 表示 rating IS NULL OR rating = 0）
    let unrated = try await catalog.query(SearchQuery(scope: scopeA, minimumRating: 0))
    #expect(Set(unrated.hits.map(\.entry.location)) == [a3.location, a4.location, aSub.location])

    // 多标签全部命中
    let multiTag = try await catalog.query(SearchQuery(scope: scopeA, tags: ["精选", "风景"]))
    #expect(Set(multiTag.hits.map(\.entry.location)) == [a1.location, aNested.location])

    // 类型筛选
    let mediaOnly = try await catalog.query(SearchQuery(scope: scopeA, kinds: [.video, .archive]))
    #expect(Set(mediaOnly.hits.map(\.entry.location)) == [a3.location, a4.location])

    // limit 与 truncated
    let limited = try await catalog.query(SearchQuery(scope: scopeA, limit: 2))
    #expect(limited.hits.count == 2)
    #expect(limited.truncated)

    // tagSuggestions：按出现次数降序排列（精选:4, 风景:3, 人像:1, 旅行:1）
    let allSuggestions = try await catalog.tagSuggestions(prefix: "", limit: 10)
    #expect(allSuggestions == ["精选", "风景", "人像", "旅行"])

    let prefixSuggestions = try await catalog.tagSuggestions(prefix: "精", limit: 10)
    #expect(prefixSuggestions == ["精选"])
}

// MARK: C1.8 update / apply 一致性与旧库迁移保留原缩略图索引

@Test func directoryCacheUpdateAndApplyKeepSearchEntriesConsistent() async throws {
    let directory = try SearchTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let directoryCache = DirectoryCache(index: index)
    let catalog = SearchCatalog(index: index)

    let root = Location(root: .local, layers: [["sync"]])
    let uncached = root.appending("uncached")
    let a = makeEntry("a.jpg", in: root, size: 100, modified: 1)
    let b = makeEntry("b.jpg", in: root, size: 200, modified: 1)
    _ = try await directoryCache.update(root, listing: DirectoryListing(entries: [a, b]))
    #expect(try await catalog.indexedCount(under: root) == 2)

    // update 增删改
    let aModified = makeEntry("a.jpg", in: root, size: 150, modified: 2)
    let c = makeEntry("c.jpg", in: root, size: 300, modified: 1)
    _ = try await directoryCache.update(root, listing: DirectoryListing(entries: [aModified, c]))
    let afterUpdate = try await catalog.query(SearchQuery(scope: root))
    #expect(Set(afterUpdate.hits.map(\.entry)) == [aModified, c])

    // apply: added, removed, moved, rewritten（以及未缓存目录上的 rewritten 跳过）
    let d = makeEntry("d.jpg", in: root, size: 400, modified: 1)
    let cMoved = makeEntry("c-renamed.jpg", in: root, size: 300, modified: 1)
    let aRewritten = makeEntry("a.jpg", in: root, size: 160, modified: 3)
    let ghostRewritten = makeEntry("ghost.jpg", in: uncached, size: 50, modified: 2)
    let meta = ImageMetadata(pixelSize: PixelSize(width: 10, height: 10), rating: 5, tags: ["精选"])
    try await directoryCache.apply([
        .added(d),
        .moved(from: c.location, to: cMoved),
        .rewritten(aRewritten, previous: aModified.identity, metadata: meta),
        .rewritten(ghostRewritten, previous: makeEntry("ghost.jpg", in: uncached).identity, metadata: meta),
        .removed(d.location),
    ])

    let cached = try #require(try await directoryCache.cachedChildren(of: root))
    let queried = try await catalog.query(SearchQuery(scope: root))
    #expect(Set(cached.entries) == [aRewritten, cMoved])
    #expect(Set(queried.hits.map(\.entry)) == Set(cached.entries))
    #expect(try await directoryCache.cachedChildren(of: uncached) == nil)
    #expect(try await catalog.indexedCount(under: uncached) == 0)
}

@Test func migrationFromCacheV2PreservesExistingDiskEntries() async throws {
    let directory = try SearchTestDirectory()
    defer { directory.remove() }

    // 构造仅有 cache-v2 的旧库，并写入一条缩略图索引与一条旧元数据
    do {
        var config = Configuration()
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(path: directory.database.path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("cache-v2") { database in
            try database.execute(sql: """
                CREATE TABLE disk_entries (
                    tier TEXT NOT NULL, key TEXT NOT NULL, filename TEXT NOT NULL,
                    size INTEGER NOT NULL, accessed REAL NOT NULL,
                    PRIMARY KEY (tier, key)
                ) WITHOUT ROWID;
                CREATE INDEX disk_entries_lru ON disk_entries(tier, accessed);
                CREATE TABLE metadata (
                    key TEXT PRIMARY KEY NOT NULL, container BLOB NOT NULL,
                    width INTEGER NOT NULL, height INTEGER NOT NULL, frameCount INTEGER NOT NULL,
                    duration REAL, capturedAt REAL, colorSpace TEXT
                ) WITHOUT ROWID;
                CREATE INDEX metadata_container ON metadata(container);
                CREATE TABLE directory_listings (location BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID;
                """)
        }
        try migrator.migrate(pool)
        try await pool.write { database in
            try database.execute(
                sql: "INSERT INTO disk_entries(tier, key, filename, size, accessed) VALUES ('thumbnails', 'oldthumbkey', 'ab/oldthumbkey', 42, 100.0)"
            )
            try database.execute(
                sql: "INSERT INTO metadata(key, container, width, height, frameCount) VALUES ('oldmeta', ?, 800, 600, 1)",
                arguments: [Data("{}".utf8)]
            )
        }
    }

    // 用新版本 CacheIndex 打开旧库，确认迁移不清空已有缩略图索引且新表可用
    let index = try CacheIndex(databaseURL: directory.database)
    let diskCache = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: 1024, index: index)
    #expect(try await diskCache.contains("oldthumbkey"))

    let metadataIndex = MetadataIndex(index: index)
    let existingMeta = try await metadataIndex.values(for: ["oldmeta"])
    #expect(existingMeta["oldmeta"]?.pixelSize == PixelSize(width: 800, height: 600))
    #expect(existingMeta["oldmeta"]?.rating == nil)
    #expect(existingMeta["oldmeta"]?.tags == nil)

    let catalog = SearchCatalog(index: index)
    #expect(try await catalog.indexedCount(under: Location(root: .local)) == 0)
}

// MARK: C1.9 DiskCache.rekey 与 MetadataIndex.move

@Test func diskCacheRekeyAndMetadataIndexMovePreserveCachedData() async throws {
    let directory = try SearchTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let diskCache = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: 10_000, index: index)
    let metadataIndex = MetadataIndex(index: index)
    let directoryCache = DirectoryCache(index: index)
    let catalog = SearchCatalog(index: index)

    // DiskCache.rekey：同时改挂主 key 和带后缀的 key，不存在的前缀跳过不报错
    try await diskCache.store(Data([1, 2, 3]), for: "oldprefix")
    try await diskCache.store(Data([4, 5, 6]), for: "oldprefix|thumb|256")
    try await diskCache.store(Data([7, 8]), for: "otherkey")
    try await diskCache.rekey(prefix: "oldprefix", to: "newprefix")
    try await diskCache.rekey(prefix: "nonexistent", to: "whatever")

    #expect(try await diskCache.data(for: "oldprefix") == nil)
    #expect(try await diskCache.data(for: "oldprefix|thumb|256") == nil)
    #expect(try await diskCache.data(for: "newprefix") == Data([1, 2, 3]))
    #expect(try await diskCache.data(for: "newprefix|thumb|256") == Data([4, 5, 6]))
    #expect(try await diskCache.data(for: "otherkey") == Data([7, 8]))

    // MetadataIndex.move：评分和标签随新 key 迁移，并能在 SearchCatalog 下筛出
    let root = Location(root: .local, layers: [["move"]])
    let oldEntry = makeEntry("old.jpg", in: root, size: 100, modified: 1)
    let newEntry = makeEntry("new.jpg", in: root, size: 100, modified: 1)
    _ = try await directoryCache.update(root, listing: DirectoryListing(entries: [oldEntry]))
    try await metadataIndex.store([
        oldEntry.identity.cacheKey: ImageMetadata(pixelSize: PixelSize(width: 640, height: 480), rating: 5, tags: ["精选", "人像"]),
    ], in: root)

    try await directoryCache.apply([.moved(from: oldEntry.location, to: newEntry)])
    try await metadataIndex.move([
        (from: oldEntry.identity.cacheKey, to: newEntry.identity.cacheKey, container: root),
        (from: "missing-key", to: "unused-key", container: root),
    ])

    #expect(try await metadataIndex.values(for: [oldEntry.identity.cacheKey]).isEmpty)
    let movedMeta = try #require(try await metadataIndex.values(for: [newEntry.identity.cacheKey])[newEntry.identity.cacheKey])
    #expect(movedMeta.rating == 5)
    #expect(movedMeta.tags == ["人像", "精选"])

    let result = try await catalog.query(SearchQuery(scope: root, minimumRating: 5, tags: ["精选"]))
    #expect(result.hits.map(\.entry.location) == [newEntry.location])
}

// MARK: C1.17 目录删除与移动后子树搜索行清理/迁前缀

@Test func directoryRemovalAndMoveUpdateEntireSubtreeInSearchIndex() async throws {
    let directory = try SearchTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let directoryCache = DirectoryCache(index: index)
    let catalog = SearchCatalog(index: index)

    let root = Location(root: .local, layers: [["tree"]])
    let dirA = root.appending("dirA")
    let dirASub = dirA.appending("nested")
    let dirB = root.appending("dirB")

    let dirAEntry = makeEntry("dirA", in: root, kind: .directory)
    let nestedEntry = makeEntry("nested", in: dirA, kind: .directory)
    let img1 = makeEntry("photo1.jpg", in: dirA)
    let img2 = makeEntry("photo2.jpg", in: dirASub)

    _ = try await directoryCache.update(root, listing: DirectoryListing(entries: [dirAEntry]))
    _ = try await directoryCache.update(dirA, listing: DirectoryListing(entries: [nestedEntry, img1]))
    _ = try await directoryCache.update(dirASub, listing: DirectoryListing(entries: [img2]))
    #expect(try await catalog.indexedCount(under: dirA) == 3)

    // 移动目录 dirA -> dirB
    let dirBEntry = makeEntry("dirB", in: root, kind: .directory)
    try await directoryCache.apply([.moved(from: dirA, to: dirBEntry)])

    #expect(try await catalog.indexedCount(under: dirA) == 0)
    #expect(try await catalog.indexedCount(under: dirB) == 3)
    let movedHits = try await catalog.query(SearchQuery(terms: ["photo"], scope: dirB))
    #expect(Set(movedHits.hits.map(\.entry.location)) == [
        dirB.appending("photo1.jpg"),
        dirB.appending("nested").appending("photo2.jpg"),
    ])

    // 删除目录 dirB（经 apply .removed）
    try await directoryCache.apply([.removed(dirB)])
    #expect(try await catalog.indexedCount(under: dirB) == 0)
    #expect(try await catalog.indexedCount(under: root) == 0)

    // 子目录经 update 消失时也清理子树
    let dirC = root.appending("dirC")
    let dirCEntry = makeEntry("dirC", in: root, kind: .directory)
    _ = try await directoryCache.update(root, listing: DirectoryListing(entries: [dirCEntry]))
    _ = try await directoryCache.update(dirC, listing: DirectoryListing(entries: [makeEntry("leaf.jpg", in: dirC)]))
    #expect(try await catalog.indexedCount(under: dirC) == 1)

    _ = try await directoryCache.update(root, listing: DirectoryListing(entries: []))
    #expect(try await catalog.indexedCount(under: dirC) == 0)
    #expect(try await catalog.indexedCount(under: root) == 0)
}
