import Darwin
import Foundation
import MVFoundation
import SQLite3
import Synchronization
import Testing
@testable import MVSettings

@Test func documentDefaultsWriteOnlyOnUpdateAndKeepEnvelope() async throws {
    let directory = try SettingsDirectory()
    let file = directory.url.appending(path: "layout.json")
    let document = try JSONDocumentStore(fileURL: file, version: 3, defaultValue: ["width": 100])
    #expect(document.value() == ["width": 100])
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let events = ChangeRecorder(document.changes())
    defer { events.cancel() }
    try await document.update { $0["width"] = 240 }
    try await settingsWait { events.values.contains(.reloaded) }
    let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(envelope["version"] as? Int == 3)
    #expect(envelope["value"] as? [String: Int] == ["width": 240])
    #expect(try JSONDocumentStore(fileURL: file, version: 3, defaultValue: [String: Int]()).value() == document.value())
}

@Test func directoryAndFileMonitoringSurviveAtomicReplacementAndInPlaceWrites() async throws {
    let directory = try SettingsDirectory()
    let file = directory.url.appending(path: "layout.json")
    let document = try JSONDocumentStore(fileURL: file, version: 1, defaultValue: 0)
    let events = ChangeRecorder(document.changes())
    defer { events.cancel() }
    for value in 1...3 {
        let before = events.values.count
        try writeSettingsDocument(value, to: file)
        try await settingsWait(timeout: .seconds(1)) {
            document.value() == value && events.values.count > before
        }
    }
    let before = events.values.count
    try Data(#"{"version":1,"value":4}"#.utf8).write(to: file)
    try await settingsWait(timeout: .seconds(1)) { document.value() == 4 && events.values.count > before }
    try FileManager.default.removeItem(at: file)
    try await settingsWait { document.value() == 0 }
    try writeSettingsDocument(5, to: file)
    try await settingsWait { document.value() == 5 }
}

@Test func malformedAndFutureDocumentsKeepTheLastGoodValue() async throws {
    let directory = try SettingsDirectory()
    let file = directory.url.appending(path: "layout.json")
    try writeSettingsDocument(10, to: file)
    let document = try JSONDocumentStore(fileURL: file, version: 1, defaultValue: 0)
    let events = ChangeRecorder(document.changes())
    defer { events.cancel() }
    try Data("{\n  \"version\":1,\n  \"value\": ]\n}".utf8).write(to: file, options: .atomic)
    try await settingsWait { events.values.contains { if case .fileError = $0 { true } else { false } } }
    #expect(document.value() == 10)
    let error = try #require(events.values.compactMap { event -> String? in
        if case let .fileError(message) = event { return message }; return nil
    }.last)
    #expect(error.contains("行") && error.contains("列"))
    try writeSettingsDocument(20, to: file, version: 2)
    try await settingsWait { events.values.contains { if case let .fileError(message) = $0 { message.contains("版本 2") } else { false } } }
    #expect(document.value() == 10)
    let count = events.values.count
    try writeSettingsDocument("wrong type", to: file)
    try await settingsWait { events.values.count > count }
    #expect(document.value() == 10)
    try writeSettingsDocument(30, to: file)
    try await settingsWait { document.value() == 30 }
}

@Test func startupErrorsAreDeliveredToLateSubscribers() async throws {
    let directory = try SettingsDirectory()
    let file = directory.url.appending(path: "layout.json")
    try writeSettingsDocument(20, to: file, version: 2)
    let document = try JSONDocumentStore(fileURL: file, version: 1, defaultValue: 7)
    #expect(document.value() == 7)
    var iterator = document.changes().makeAsyncIterator()
    let first = await iterator.next()
    #expect(first.map { if case let .fileError(message) = $0 { message.contains("行") && message.contains("列") } else { false } } == true)
    try Data("{ invalid".utf8).write(to: directory.url.appending(path: "settings.json"))
    let store = try FileSettingsStore(directory: directory.url)
    #expect(await store.global() == .default)
    var settingsIterator = store.changes().makeAsyncIterator()
    #expect(await settingsIterator.next().map { if case let .fileError(file, _) = $0 { file == "settings.json" } else { false } } == true)
}

@Test func missingGlobalFieldsAreFilledAndReportedWithoutRewritingTheFile() async throws {
    let directory = try SettingsDirectory()
    let file = directory.url.appending(path: "settings.json")
    let data = Data(#"{"version":1,"value":{"defaultBook":{"sort":{"key":"size"}},"cache":{"rawBytes":123},"maxDecodeLongSide":4096}}"#.utf8)
    try data.write(to: file)
    let store = try FileSettingsStore(directory: directory.url)
    var expected = GlobalSettings.default
    expected.defaultBook.sort.key = .size
    expected.cache.rawBytes = 123
    expected.maxDecodeLongSide = 4096
    #expect(await store.global() == expected)
    var iterator = store.changes().makeAsyncIterator()
    let event = await iterator.next()
    #expect(event.map { if case let .fileError(file, message) = $0 {
        file == "settings.json" && message.contains("defaultBook.sort.ascending") && message.contains("prefetch")
    } else { false } } == true)
    #expect(try Data(contentsOf: file) == data)
}

@Test func globalRulesAndMemoryMergeByFieldAcrossArchiveLayers() async throws {
    let directory = try SettingsDirectory()
    let root = Location.Root.network(scheme: "smb", host: "nas", share: "Picture")
    let outer = Location(root: root, layers: [["Comics"]])
    let inner = outer.appending("Author")
    let book = inner.appending("collection.zip").appendingLayer(["volume", "book.zip"]).appendingLayer(["book"])
    var global = GlobalSettings.default
    global.defaultBook.browseMode = .waterfall
    global.defaultBook.allowUpscale = true
    try writeSettingsDocument(global, to: directory.url.appending(path: "settings.json"))
    // 故意把具体规则排在前面，确认匹配后按前缀深度应用。
    let rules = [
        PathRule(name: "作者", prefix: inner, settings: BookSettings(direction: .leftToRight, scaleMode: .fitWidth)),
        PathRule(name: "漫画", prefix: outer, settings: BookSettings(pageMode: .double, direction: .rightToLeft)),
        PathRule(name: "包内", prefix: inner.appending("collection.zip").appendingLayer(["volume"]), settings: BookSettings(sharpen: 0.25)),
    ]
    try writeSettingsDocument(rules, to: directory.url.appending(path: "path-rules.json"))
    let store = try FileSettingsStore(directory: directory.url)
    await store.saveBookMemory(BookMemory(book: book, settings: BookSettings(firstPageSingle: false, sort: SortSpec(key: .modified))))
    let resolved = await store.resolve(for: book)
    #expect(resolved.browseMode == .waterfall)
    #expect(resolved.allowUpscale)
    #expect(resolved.pageMode == .double)
    #expect(resolved.direction == .leftToRight)
    #expect(resolved.scaleMode == .fitWidth)
    #expect(resolved.sharpen == 0.25)
    #expect(!resolved.firstPageSingle)
    #expect(resolved.sort.key == .modified)
    #expect(await store.resolve(for: Location(root: .local, layers: book.layers)) == global.defaultBook)
    #expect(await store.resolve(for: Location(root: root, layers: [["ComicsOther", "a.zip"]])) == global.defaultBook)
    try await store.flush()
}

@Test func externalSettingsAndRulesEmitTheirOwnChangesWithinOneSecond() async throws {
    let directory = try SettingsDirectory()
    let store = try FileSettingsStore(directory: directory.url)
    let events = ChangeRecorder(store.changes())
    defer { events.cancel() }
    var global = GlobalSettings.default
    global.maxDecodeLongSide = 2048
    try writeSettingsDocument(global, to: directory.url.appending(path: "settings.json"))
    try await settingsWait(timeout: .seconds(1)) { events.values.contains(.global) }
    #expect(await store.global().maxDecodeLongSide == 2048)
    let book = Location(root: .local, layers: [["comics", "a.zip"]])
    try writeSettingsDocument([PathRule(name: "目录", prefix: book.parent!, settings: BookSettings(pageMode: .double))],
                              to: directory.url.appending(path: "path-rules.json"))
    try await settingsWait(timeout: .seconds(1)) { events.values.contains(.pathRules) }
    #expect(await store.resolve(for: book).pageMode == .double)
    try await store.updateGlobal { $0.maxDecodeLongSide = 1024 }
    #expect(await (try FileSettingsStore(directory: directory.url)).global().maxDecodeLongSide == 1024)
}

@Test func updatePathRulesIsVisibleToResolveAndEmitsPathRules() async throws {
    let directory = try SettingsDirectory()
    let store = try FileSettingsStore(directory: directory.url)
    let events = ChangeRecorder(store.changes())
    defer { events.cancel() }
    let book = Location(root: .local, layers: [["comics", "a.zip"]])
    let rule = PathRule(name: "目录", prefix: book.parent!, settings: BookSettings(pageMode: .double))
    try await store.updatePathRules { $0.append(rule) }
    #expect(await store.resolve(for: book).pageMode == .double)
    #expect(await store.pathRules() == [rule])
    let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.url.appending(path: "path-rules.json"))) as? [String: Any])
    #expect(envelope["version"] as? Int == 1)
    try await settingsWait { events.values.contains(.pathRules) }
    #expect(await (try FileSettingsStore(directory: directory.url)).resolve(for: book).pageMode == .double)
}

@Test func aThousandBookMemoriesCoalesceFlushAndSurviveReopening() async throws {
    let directory = try SettingsDirectory()
    let memories = (0..<1000).map { index in
        let book = Location(root: .local, layers: [["books", "\(index).zip"], ["nested"]])
        return BookMemory(book: book, settings: BookSettings(pageMode: index.isMultiple(of: 2) ? .single : .double),
                          lastPage: book.appending("\(index).jpg"), lastPageIndex: index,
                          openedAt: Date(timeIntervalSince1970: Double(index)))
    }
    do {
        let store = try FileSettingsStore(directory: directory.url)
        for memory in memories {
            var stale = memory
            stale.lastPageIndex = -1
            await store.saveBookMemory(stale)
            await store.saveBookMemory(memory)
        }
        for memory in memories { #expect(await store.bookMemory(for: memory.book) == memory) }
        try await store.flush()
        try await store.flush()
    }
    let reopened = try FileSettingsStore(directory: directory.url)
    for memory in memories { #expect(await reopened.bookMemory(for: memory.book) == memory) }
}

@Test func periodicMemoryWritesPersistWithoutExplicitFlush() async throws {
    let directory = try SettingsDirectory()
    let store = try FileSettingsStore(directory: directory.url)
    let book = Location(root: .local, layers: [["book"]])
    let memory = BookMemory(book: book, lastPageIndex: 9)
    await store.saveBookMemory(memory)
    try await settingsWait(timeout: .seconds(2)) {
        let reopened = try FileSettingsStore(directory: directory.url)
        return await reopened.bookMemory(for: book) == memory
    }
}

@Test func stateDatabaseOpenSucceedsAfterWriteLockReleased() async throws {
    let directory = try SettingsDirectory()
    let path = directory.url.appending(path: "state.sqlite").path
    var connection: OpaquePointer?
    #expect(sqlite3_open(path, &connection) == SQLITE_OK)
    let sqlite = try #require(connection)
    defer {
        if connection != nil { sqlite3_close(sqlite) }
    }
    #expect(sqlite3_exec(sqlite, "PRAGMA journal_mode = DELETE", nil, nil, nil) == SQLITE_OK)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(sqlite, "PRAGMA journal_mode", -1, &statement, nil) == SQLITE_OK)
    let modeStatement = try #require(statement)
    #expect(sqlite3_step(modeStatement) == SQLITE_ROW)
    let mode = sqlite3_column_text(modeStatement, 0).map { String(cString: $0) }
    #expect(mode?.lowercased() != "wal")
    #expect(sqlite3_finalize(modeStatement) == SQLITE_OK)
    #expect(sqlite3_exec(sqlite, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

    let result = Mutex<(done: Bool, error: String?)>((false, nil))
    DispatchQueue.global().async {
        do {
            _ = try FileSettingsStore(directory: directory.url)
            result.withLock { $0 = (true, nil) }
        } catch {
            result.withLock { $0 = (true, String(describing: error)) }
        }
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!result.withLock { $0.done })
    #expect(sqlite3_exec(sqlite, "COMMIT", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_close(sqlite) == SQLITE_OK)
    connection = nil

    try await settingsWait(timeout: .seconds(2)) { result.withLock { $0.done } }
    #expect(result.withLock { $0.error } == nil)
}

@Test func concurrentOpenAndClosePreservesBookMemory() async throws {
    let directory = try SettingsDirectory()
    let book = Location(root: .local, layers: [["books", "concurrent.zip"]])
    let memory = BookMemory(book: book, settings: BookSettings(pageMode: .double),
                            lastPage: book.appending("42.jpg"), lastPageIndex: 42,
                            openedAt: Date(timeIntervalSince1970: 42))
    do {
        let store = try FileSettingsStore(directory: directory.url)
        await store.saveBookMemory(memory)
        try await store.flush()
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<50 {
            group.addTask {
                let store = try FileSettingsStore(directory: directory.url)
                #expect(await store.bookMemory(for: book) == memory)
            }
        }
        try await group.waitForAll()
    }

    let reopened = try FileSettingsStore(directory: directory.url)
    #expect(await reopened.bookMemory(for: book) == memory)
}

@Test func concurrentDocumentUpdatesDoNotLoseChanges() async throws {
    let directory = try SettingsDirectory()
    let document = try JSONDocumentStore(fileURL: directory.url.appending(path: "counter.json"), version: 1, defaultValue: 0)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<100 { group.addTask { try await document.update { $0 += 1 } } }
        try await group.waitForAll()
    }
    #expect(document.value() == 100)
}

@Test func sigkillDuringSettingsWritesLeavesACompleteDocument() async throws {
    let directory = try SettingsDirectory()
    let executable = Bundle(for: SettingsBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "mvtest-writer")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    let process = Process()
    process.executableURL = executable
    process.arguments = ["settings", directory.url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }
    let file = directory.url.appending(path: "settings.json")
    try await settingsWait(timeout: .seconds(5)) { FileManager.default.fileExists(atPath: file.path) }
    try await Task.sleep(for: .milliseconds(30))
    #expect(process.isRunning)
    #expect(kill(process.processIdentifier, SIGKILL) == 0)
    process.waitUntilExit()
    #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
    let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(envelope["version"] as? Int == 1)
    let value = try #require(envelope["value"])
    let global = try JSONDecoder().decode(GlobalSettings.self, from: JSONSerialization.data(withJSONObject: value))
    #expect(global.maxDecodeLongSide > 8192)
    #expect(global.defaultBook.fixedScale == Double(global.maxDecodeLongSide - 8192))
    #expect(await (try FileSettingsStore(directory: directory.url)).global() == global)
}

private struct SettingsEnvelope<Value: Encodable>: Encodable { var version: Int; var value: Value }

private func writeSettingsDocument<Value: Encodable>(_ value: Value, to file: URL, version: Int = 1) throws {
    try JSONEncoder().encode(SettingsEnvelope(version: version, value: value)).write(to: file, options: .atomic)
}

private func settingsWait(timeout: Duration = .seconds(1), _ condition: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw SettingsTestError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private enum SettingsTestError: Error { case timeout }
private final class SettingsBundleMarker: NSObject {}

private final class ChangeRecorder<Change: Sendable>: Sendable {
    private let storage = Mutex<[Change]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)
    var values: [Change] { storage.withLock { $0 } }
    init(_ stream: AsyncStream<Change>) {
        let task = Task { [weak self] in
            for await change in stream { self?.storage.withLock { $0.append(change) } }
        }
        self.task.withLock { $0 = task }
    }
    func cancel() { task.withLock { $0?.cancel() } }
}

private final class SettingsDirectory: Sendable {
    let url: URL
    init() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        url = root.appending(path: "build/stage-1-work/settings-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
