import CryptoKit
import Darwin
import Foundation
import MVCommands
import MVFoundation
import MVLibraryData
import MVPlugins
import MVScripting
import MVSettings
import Testing
@testable import MVServices

private let origin = UserDataOrigin(appVersion: "1.2", appBuild: "34", host: "测试 Mac")
private var manager: FileManager { .default }
private let appItems: [UserDataItem] = [.layout, .layoutSchemes, .session]
private let appValidators: UserDataValidators = Dictionary(uniqueKeysWithValues: appItems.map { item in
    (item, { @Sendable data in try JSONDocumentStore<[String]>.validate(data, version: 1) })
})

private final class ArchiveFixture: Sendable {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: ".archive-test-\(UUID())", directoryHint: .isDirectory)
    let source: UserDataLocations
    let target: UserDataLocations
    var zip: URL { root.appending(path: "export.macviewdata") }
    var staging: URL { target.supportDirectory.appending(path: ".import-staging") }
    var rollback: URL { target.supportDirectory.appending(path: ".import-rollback") }

    init() throws {
        let first = root.appending(path: "source"), second = root.appending(path: "target")
        source = UserDataLocations(supportDirectory: first, layoutFile: root.appending(path: "layout A"))
        target = UserDataLocations(supportDirectory: second, layoutFile: root.appending(path: "layout B"))
        for directory in [first, second] { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    deinit { try? manager.removeItem(at: root) }

    @MainActor func populateStores(in locations: UserDataLocations, memory: BookMemory) async throws -> CoreServices {
        let core = try await CoreServices.make(configuration: .init(supportDirectory: locations.supportDirectory,
            cacheDirectory: root.appending(path: "cache"), browseBounds: PixelSize(width: 640, height: 480)))
        await core.settings.saveBookMemory(memory)
        try await core.settings.updateGlobal { $0.historyLimit = 42 }
        try await core.settings.updatePathRules { _ in }
        try await core.settings.updateProfiles { _ in }
        try await core.keyBindings?.update { _ in }
        try await core.menus?.update { _ in }
        try await core.externalCommands?.update { _ in }
        try await core.pluginSettings?.update { $0.plugins["sample"] = .init(enabled: true) }
        try await core.scriptStorage?.set("sample", "note", .string("note"))
        let sourceID = UUID()
        try await core.pluginSecrets?.set(["test": "fixture"], for: sourceID)
        let library = try #require(core.library)
        try await library.recordOpened(memory.book, at: Date(timeIntervalSince1970: 123))
        let folder = try await library.addBookmarkFolder(named: "收藏", into: nil, at: nil)
        _ = try await library.addBookmarks([memory.book], into: folder, at: 0)
        _ = try await library.createPlaylist(named: "列表")
        for item in appItems {
            let store = try JSONDocumentStore(fileURL: item.url(in: locations), version: 1, defaultValue: [String]())
            try await store.update { $0 = ["fixture"] }
        }
        return core
    }

    @discardableResult func export() async throws -> UserDataManifest {
        try await UserDataArchive.export(from: source, origin: origin, appValidators: appValidators, to: zip)
    }

    @discardableResult func stageAndCommit(_ url: URL? = nil) async throws -> StagedImport {
        let staged = try await UserDataArchive.stage(url ?? zip, for: target, appValidators: appValidators)
        try UserDataArchive.commitStaged(staged, for: target)
        return staged
    }

    func applyPendingImport() async -> UserDataImportOutcome? {
        await UserDataArchive.applyPendingImport(for: target, origin: origin, appValidators: appValidators)
    }

    func snapshot(_ url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for file in try manager.subpathsOfDirectory(atPath: url.path) {
            let path = url.appending(path: file)
            let attrs = try manager.attributesOfItem(atPath: path.path)
            switch attrs[.type] as? FileAttributeType {
            case .typeDirectory: result[file] = "dir"
            case .typeSymbolicLink: result[file] = try manager.destinationOfSymbolicLink(atPath: path.path)
            default: result[file] = SHA256.hash(data: try Data(contentsOf: path)).description
            }
        }
        return result
    }

    // 修改导出包使用系统工具，确保走正常导入入口。
    func changeZip(_ code: String, _ args: [String] = []) throws {
        _ = try command("/usr/bin/python3", ["-c", """
            import sys, zipfile
            path = sys.argv[1]
            with zipfile.ZipFile(path) as src:
                entries = {name: src.read(name) for name in src.namelist()}
            \(code)
            with zipfile.ZipFile(path, 'w') as dst:
                for name, data in entries.items(): dst.writestr(name, data)
            """, zip.path] + args)
    }
}

@discardableResult private func command(_ executable: String, _ arguments: [String]) throws -> String {
    let task = Process(), output = Pipe()
    task.executableURL = URL(filePath: executable)
    task.arguments = arguments
    task.standardOutput = output
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    return String(decoding: data, as: UTF8.self)
}

private func write(_ text: String, _ url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func mode(_ url: URL) throws -> Int? {
    try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}

// 归档会启动子进程并连续写 SQLite，与同模块的一秒退出计时共用串行套件。
extension CoreIntegrationTests {
    @Suite(.serialized) struct UserDataArchiveTests {}
}

extension CoreIntegrationTests.UserDataArchiveTests {
    @Test("C1.1 / C1.4c 16 项按真实存储往返，统计来自快照，权限、链接与空目录保留")
    @MainActor func roundTrip() async throws {
        let f = try ArchiveFixture()
        let book = Location(root: .local, layers: [["书 O'Brien"]])
        let memory = BookMemory(book: book, lastPageIndex: 4)
        let core = try await f.populateStores(in: f.source, memory: memory)
        let library = try #require(core.library)
        let scripts = UserDataItem.scripts.url(in: f.source)
        try write("sample", scripts.appending(path: "测试.js"))
        let plugin = UserDataItem.pluginFiles.url(in: f.source).appending(path: "test")
        try manager.createDirectory(at: plugin.appending(path: "empty"), withIntermediateDirectories: true)
        try write("{}", plugin.appending(path: "manifest.json"))
        let executable = plugin.appending(path: "run")
        try write("sample", executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try manager.createSymbolicLink(atPath: plugin.appending(path: "link").path, withDestinationPath: "run")
        // 旧版 zipinfo 会将这两个名称显示为相同的字节串。实际的目录和链接是不同条目。
        try manager.createDirectory(at: plugin.appending(path: "一"), withIntermediateDirectories: false)
        try write("child", plugin.appending(path: "一/child"))
        try manager.createSymbolicLink(atPath: plugin.appending(path: "丁").path, withDestinationPath: "一")
        try command("/usr/bin/xattr", ["-w", "com.macview.fixture", "sample", executable.path])
        try write("fixture", URL(filePath: executable.path + "/..namedfork/rsrc"))
        try await core.flushPersistentState()
        let expectedScripts = try manager.contentsOfDirectory(atPath: scripts.path).filter { $0.hasSuffix(".js") }.count
        try write("old export", f.zip)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.zip.path)
        let manifest = try await f.export()
        #expect(Set(manifest.items) == Set(UserDataItem.allCases))
        #expect(manifest.summary == .init(history: 1, bookmarks: 1, playlists: 1, scripts: expectedScripts, plugins: 1))
        #expect(try mode(f.zip) == 0o600)
        let listing = try command("/usr/bin/zipinfo", ["-1", f.zip.path])
        #expect(!listing.contains("__MACOSX") && !listing.contains("/._"))
        #expect(!listing.contains(".sqlite-wal") && !listing.contains(".sqlite-shm"))
        let staged = try await f.stageAndCommit()
        #expect(staged.manifest == manifest)
        let result = await f.applyPendingImport()
        #expect(result == .imported(manifest, backup: UserDataArchive.backupURL(for: f.target)))
        for item in UserDataItem.allCases {
            let a = item.url(in: f.source), b = item.url(in: f.target)
            switch item.kind {
            case .json: #expect(try Data(contentsOf: a) == Data(contentsOf: b))
            case .directory: #expect(try f.snapshot(a) == f.snapshot(b))
            case .sqlite: break
            }
        }
        #expect(try mode(UserDataItem.pluginFiles.url(in: f.target).appending(path: "test/run")) == 0o755)
        #expect(try mode(UserDataItem.pluginSecrets.url(in: f.target)) == 0o600)
        let settings = try FileSettingsStore(directory: f.target.supportDirectory)
        #expect(await settings.bookMemory(for: book) == memory)
        let restored = try SQLiteLibraryStore(databaseURL: UserDataItem.library.url(in: f.target), historyLimit: 100)
        let expectedBookmarks = try await library.bookmarks()
        #expect(try await restored.bookmarks() == expectedBookmarks)
        let expectedHistory = try await library.history()
        #expect(try await restored.history() == expectedHistory)
        let expectedPlaylists = try await library.playlists()
        #expect(try await restored.playlists() == expectedPlaylists)
        await core.shutdown()
    }

    @Test("C1.1 在脚本或插件目录覆盖导出时只跳过本次目标", arguments: [UserDataItem.scripts, .pluginFiles])
    func exportsInsidePayload(_ item: UserDataItem) async throws {
        let f = try ArchiveFixture()
        let source: UserDataLocations
        if let mounted = ProcessInfo.processInfo.environment["MV_ARCHIVE_TEST_PAYLOAD_VOLUMES"] {
            let support = URL(filePath: mounted).appending(path: item.rawValue)
            source = UserDataLocations(supportDirectory: support, layoutFile: support.appending(path: "layout.json"))
            var supportInfo = stat(), payloadInfo = stat()
            #expect(stat(support.path, &supportInfo) == 0 && stat(item.url(in: source).path, &payloadInfo) == 0)
            #expect(supportInfo.st_dev != payloadInfo.st_dev)
        } else {
            source = f.source
        }
        let folder = "子目录-\(UUID())"
        let directory = item.url(in: source).appending(path: folder)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        try write("sample", directory.appending(path: "a.js"))
        try write("keep", directory.appending(path: "other.macviewdata"))
        let zip = directory.appending(path: "export.macviewdata")
        _ = try await UserDataArchive.export(from: source, origin: origin, appValidators: appValidators, to: zip)
        let insensitive = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
        let overwrite = insensitive ? directory.appending(path: "EXPORT.macviewdata") : zip
        let manifest = try await UserDataArchive.export(from: source, origin: origin, appValidators: appValidators, to: overwrite)
        let staged = try await f.stageAndCommit(overwrite)
        #expect(staged.manifest == manifest)
        let copied = f.staging.appending(path: "data").appending(path: item.rawValue).appending(path: folder)
        #expect(try Set(manager.contentsOfDirectory(atPath: copied.path)) == ["a.js", "other.macviewdata"])
        #expect(try !command("/usr/bin/zipinfo", ["-1", overwrite.path]).contains("/.macview-export-"))
    }

    @Test("C1.2 并发写入期间导出的库含导出前已提交的历史")
    func concurrentSnapshot() async throws {
        let f = try ArchiveFixture()
        let library = try SQLiteLibraryStore(databaseURL: UserDataItem.library.url(in: f.source), historyLimit: 16)
        let committed = (0..<3).map { Location(root: .local, layers: [["committed-\($0)"]]) }
        let active = (0..<4).map { Location(root: .local, layers: [["page-\($0)"]]) }
        for book in committed { try await library.recordOpened(book, at: .now) }
        try await withThrowingTaskGroup(of: Int.self) { group in
            let (started, signal) = AsyncStream<Void>.makeStream()
            group.addTask {
                defer { signal.finish() }
                var count = 0
                while !Task.isCancelled {
                    try await library.recordOpened(active[count % active.count], at: .now)
                    count += 1
                    if count == 1 { signal.yield() }
                    if count > 1 { try? await Task.sleep(for: .milliseconds(2)) }
                }
                return count
            }
            for await _ in started {
                try await f.export()
                break
            }
            group.cancelAll()
            #expect((try await group.next() ?? 0) > 1)
        }
        _ = try await f.stageAndCommit() // 包含 quick_check
        let snapshot = try SQLiteLibraryStore(databaseURL: f.staging.appending(path: "data/library.sqlite"), historyLimit: 16)
        let exported = Set(try await snapshot.history().map(\.book))
        #expect(Set(committed).isSubset(of: exported))
        #expect(exported.contains(active[0]))
    }

    @Test("C1.3 / C1.5 白名单外的文件保留，缺项删除，再导入备份可反悔")
    func backupAndRestore() async throws {
        let f = try ArchiveFixture()
        let old = UserDataItem.layout.url(in: f.target), session = UserDataItem.session.url(in: f.source)
        try write(#"{"version":1,"value":["旧"]}"#, old)
        try write(#"{"version":1,"value":["新"]}"#, session)
        let kept = ["transfers.json", "Backups/keep", "unknown", "Cache/index.sqlite"]
        for path in kept {
            let url = f.target.supportDirectory.appending(path: path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(path, url)
        }
        let manifest = try await f.export()
        try await f.stageAndCommit()
        let backup = UserDataArchive.backupURL(for: f.target)
        #expect(await f.applyPendingImport() == .imported(manifest, backup: backup))
        #expect(!manager.fileExists(atPath: old.path))
        let staged = try await f.stageAndCommit(backup)
        #expect(await f.applyPendingImport() == .imported(staged.manifest, backup: backup))
        #expect(try String(contentsOf: old, encoding: .utf8) == #"{"version":1,"value":["旧"]}"#)
        #expect(!manager.fileExists(atPath: UserDataItem.session.url(in: f.target).path))
        for path in kept { #expect(try String(contentsOf: f.target.supportDirectory.appending(path: path), encoding: .utf8) == path) }
    }

    @Test("C1.5b 本机无效的会话与高版本快捷键从导出和备份中略过，备份可恢复其余数据")
    @MainActor func backupSkipsInvalidDocuments() async throws {
        let f = try ArchiveFixture()
        let session = UserDataItem.session, keys = UserDataItem.keyBindings
        let invalid = [session: "{", keys: #"{"version":\#(KeyBindingsFile.documentVersion + 1),"value":{"bindings":[]}}"#]
        let memory = BookMemory(book: Location(root: .local, layers: [["书"]]), lastPageIndex: 17)
        do {
            let core = try await f.populateStores(in: f.target, memory: memory)
            try await core.flushPersistentState()
            await core.shutdown()
        }
        for (item, contents) in invalid { try write(contents, item.url(in: f.target)) }
        let scripts = UserDataItem.scripts.url(in: f.target)
        try write("original", scripts.appending(path: "note.js"))
        let plugin = UserDataItem.pluginFiles.url(in: f.target).appending(path: "sample")
        try manager.createDirectory(at: plugin, withIntermediateDirectories: true)
        try write("{}", plugin.appending(path: "manifest.json"))

        // 比较 JSON 原始字节、目录内的每个条目和两个数据库的全部表、记录。
        func snapshot(_ item: UserDataItem) throws -> [String: String] {
            let url = item.url(in: f.target)
            switch item.kind {
            case .json: return ["": SHA256.hash(data: try Data(contentsOf: url)).description]
            case .directory: return try f.snapshot(url)
            case .sqlite:
                let dump = try command("/usr/bin/sqlite3", ["-batch", "-readonly", url.path, ".dump"])
                return ["": SHA256.hash(data: Data(dump.utf8)).description]
            }
        }
        let expected = Set(UserDataItem.allCases).subtracting(invalid.keys)
        let before = try Dictionary(uniqueKeysWithValues: expected.map { ($0, try snapshot($0)) })
        let manual = f.root.appending(path: "manual.macviewdata")
        let exported = try await UserDataArchive.export(from: f.target, origin: origin, appValidators: appValidators, to: manual)
        #expect(Set(exported.items) == expected)
        let manualStage = try await UserDataArchive.stage(manual, for: f.target, appValidators: appValidators)
        #expect(manualStage.manifest == exported)
        for (item, contents) in invalid {
            #expect(try Data(contentsOf: item.url(in: f.target)) == Data(contents.utf8))
        }

        // 先导入含有效会话和快捷键的归档，确认第二次导入确实删除了这两项。
        try write(#"{"version":1,"value":["新会话"]}"#, session.url(in: f.source))
        try write(#"{"version":\#(KeyBindingsFile.documentVersion),"value":{"bindings":[]}}"#, keys.url(in: f.source))
        let incoming = try await f.export()
        try await f.stageAndCommit()
        let backup = UserDataArchive.backupURL(for: f.target)
        #expect(await f.applyPendingImport() == .imported(incoming, backup: backup))
        for item in [session, keys] {
            #expect(try Data(contentsOf: item.url(in: f.target)) == Data(contentsOf: item.url(in: f.source)))
        }
        for archive in [manual, backup] {
            let entries = try command("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n")
            for item in [session, keys] { #expect(!entries.contains("data/\(item.rawValue)")) }
        }
        let staged = try await f.stageAndCommit(backup)
        #expect(Set(staged.manifest.items) == expected)
        #expect(await f.applyPendingImport() == .imported(staged.manifest, backup: backup))
        for item in [session, keys] { #expect(!manager.fileExists(atPath: item.url(in: f.target).path)) }
        for item in expected { #expect(try snapshot(item) == before[item]) }
    }

    enum Invalid: CaseIterable { case ordinary, notZip, newer, json, database, traversal, absolute, version, structure, missing, extra }
    @Test("C1.4 / C1.4b / C1.4c 拒绝非法归档，目标目录和暂存之外的文件不变", arguments: Invalid.allCases)
    func rejectsInvalid(_ invalid: Invalid) async throws {
        let f = try ArchiveFixture()
        try write("untouched", f.target.supportDirectory.appending(path: "old"))
        let before = try f.snapshot(f.target.supportDirectory)
        let escapesTo = f.root.appending(path: "escaped")
        try write(#"{"version":2,"value":{"bindings":[]}}"#, UserDataItem.keyBindings.url(in: f.source))
        do { _ = try FileSettingsStore(directory: f.source.supportDirectory) }
        _ = try await f.export()
        switch invalid {
        case .ordinary: try f.changeZip("entries = {'ordinary': b'x'}")
        case .notZip: try write("plain", f.zip)
        case .newer:
            try f.changeZip("import json\nm = json.loads(entries['manifest.json']); m['format'] = 2; entries['manifest.json'] = json.dumps(m)")
        case .json: try f.changeZip("entries['data/keybindings.json'] = b'{'")
        case .database: try f.changeZip("entries['data/state.sqlite'] = b'not sqlite'")
        case .traversal: try f.changeZip("entries['../escaped'] = b'x'")
        case .absolute: try f.changeZip("entries[sys.argv[2]] = b'x'", [escapesTo.path])
        case .version: try f.changeZip(#"entries['data/keybindings.json'] = '{"version":3,"value":{"bindings":[]}}'"#)
        case .structure: try f.changeZip(#"entries['data/keybindings.json'] = '{"version":2,"value":{}}'"#)
        case .missing: try f.changeZip("del entries['data/keybindings.json']")
        case .extra: try f.changeZip("entries['data/extra.txt'] = b'x'")
        }
        do {
            _ = try await UserDataArchive.stage(f.zip, for: f.target, appValidators: appValidators)
            Issue.record("接受了无效文件")
        } catch let error as UserDataArchiveError {
            switch (invalid, error) {
            case (.ordinary, .notAnArchive), (.notZip, .notAnArchive), (.newer, .newerFormat(2)),
                 (.database, .damaged(item: "state.sqlite", reason: _)),
                 (.json, .damaged(item: "keybindings.json", reason: _)), (.version, .damaged(item: "keybindings.json", reason: _)),
                 (.structure, .damaged(item: "keybindings.json", reason: _)),
                 (.traversal, .damaged), (.absolute, .damaged), (.missing, .damaged), (.extra, .damaged): break
            default: Issue.record("错误分类不符：\(error)")
            }
        }
        #expect(try f.snapshot(f.target.supportDirectory) == before)
        #expect(!manager.fileExists(atPath: escapesTo.path))
    }

    @Test("C1.4c 12 种 JSON 的真实校验均拒绝错误结构")
    func validatesEveryJSON() async throws {
        let f = try ArchiveFixture()
        let items = UserDataItem.allCases.filter { $0.kind == .json }
        for item in items { try write("[]", item.url(in: f.source)) }
        let manifest = try await f.export()
        #expect(manifest.items.isEmpty)
        for item in appItems {
            let validators = appValidators.filter { $0.key != item }
            await #expect(throws: UserDataArchiveError.self) {
                try await UserDataArchive.export(from: f.source, origin: origin, appValidators: validators, to: f.zip)
            }
        }
        // 共用一次真实导出的清单，每份外部包只含一个无效项，让每个校验器都走到。
        try command("/usr/bin/python3", ["-c", """
            import json, pathlib, sys, zipfile
            base = pathlib.Path(sys.argv[1])
            with zipfile.ZipFile(base) as src:
                manifest = json.loads(src.read('manifest.json'))
            for name in sys.argv[2:]:
                manifest['items'] = [name]
                with zipfile.ZipFile(base.with_name(name + '.zip'), 'w') as dst:
                    dst.writestr('manifest.json', json.dumps(manifest))
                    dst.writestr('data/' + name, b'[]')
            """, f.zip.path] + items.map(\.rawValue))
        for item in items {
            let archive = f.root.appending(path: item.rawValue + ".zip")
            do {
                _ = try await UserDataArchive.stage(archive, for: f.target, appValidators: appValidators)
                Issue.record("接受了错误结构：\(item.rawValue)")
            } catch let error as UserDataArchiveError {
                if case let .damaged(name, _) = error {
                    #expect(name == item.rawValue)
                } else {
                    Issue.record("错误分类不符：\(item.rawValue)，\(error)")
                }
            }
            #expect(try f.snapshot(f.target.supportDirectory).isEmpty)
        }
    }

    @Test("C1.4 清单项必须是普通文件，不能用指向另一文件的链接替代")
    func rejectsLinkedDocument() async throws {
        let f = try ArchiveFixture()
        _ = try await f.export()
        let payload = f.root.appending(path: "payload")
        try command("/usr/bin/ditto", ["-x", "-k", f.zip.path, payload.path])
        let manifest = payload.appending(path: "manifest.json")
        let outside = f.root.appending(path: "outside manifest")
        try manager.moveItem(at: manifest, to: outside)
        let original = try Data(contentsOf: outside)
        let permissions = try mode(outside)
        try manager.createSymbolicLink(at: manifest, withDestinationURL: outside)
        let linked = f.root.appending(path: "link.zip")
        try command("/usr/bin/ditto", ["-c", "-k", "--norsrc", payload.path, linked.path])
        do {
            _ = try await UserDataArchive.stage(linked, for: f.target, appValidators: appValidators)
            Issue.record("接受了符号链接清单")
        } catch let error as UserDataArchiveError {
            guard case .damaged = error else { Issue.record("错误分类不符"); return }
        }
        #expect(try f.snapshot(f.target.supportDirectory).isEmpty)
        #expect(try Data(contentsOf: outside) == original)
        #expect(try mode(outside) == permissions)
    }

    @Test("C1.4b 从真实归档入口拒绝子目录落在文件链接下及重复声明同一个链接", arguments: [false, true])
    func linkHierarchy(duplicate: Bool) async throws {
        let f = try ArchiveFixture()
        let scripts = UserDataItem.scripts.url(in: f.source)
        try manager.createDirectory(at: scripts, withIntermediateDirectories: false)
        try write("sample", scripts.appending(path: "note.js"))
        // 链接只指向同目录的普通夹具文件。冲突条目只携带空目录元数据或原样重复的链接。
        try manager.createSymbolicLink(atPath: scripts.appending(path: "ref").path, withDestinationPath: "note.js")
        _ = try await f.export()
        try command("/usr/bin/python3", ["-c", """
            import copy, sys, warnings, zipfile
            with zipfile.ZipFile(sys.argv[1], 'a') as z:
                if sys.argv[2] == 'repeat':
                    ref = z.getinfo('data/Scripts/ref')
                    with warnings.catch_warnings():
                        warnings.simplefilter('ignore', UserWarning)
                        z.writestr(copy.copy(ref), z.read(ref))
                else:
                    z.writestr('data/Scripts/ref/empty/', b'')
            """, f.zip.path, duplicate ? "repeat" : "child"])
        await #expect(throws: UserDataArchive.structureError) {
            try await UserDataArchive.stage(f.zip, for: f.target, appValidators: appValidators)
        }
        #expect(try f.snapshot(f.target.supportDirectory).isEmpty)
    }

    @Test("C1.3 / C1.6 导出不能替换完整目标时保留旧文件，备份失败时不开始导入", arguments: [false, true])
    func failedBackup(damagedDatabase: Bool) async throws {
        let f = try ArchiveFixture()
        try write("previous", f.zip)
        let db = UserDataItem.bookMemory.url(in: f.source)
        try write("damaged", db)
        do {
            _ = try await f.export()
            Issue.record("损坏的数据库不应导出")
        } catch let error as UserDataArchiveError {
            guard case .writeFailed = error else { Issue.record("错误分类不符"); return }
        }
        #expect(try String(contentsOf: f.zip, encoding: .utf8) == "previous")
        #expect(try !manager.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(".macview-export-") })
        try manager.removeItem(at: db)
        _ = try await f.export()
        if damagedDatabase {
            let backup = UserDataArchive.backupURL(for: f.target)
            try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: false)
            try write("previous backup", backup)
            try write("damaged", UserDataItem.bookMemory.url(in: f.target))
        } else {
            try write("keep", f.target.supportDirectory.appending(path: "Backups"))
        }
        try write("original", UserDataItem.plugins.url(in: f.target))
        let before = try f.snapshot(f.target.supportDirectory)
        try await f.stageAndCommit()
        guard case .rolledBack = await f.applyPendingImport() else {
            Issue.record("备份失败后未终止导入")
            return
        }
        #expect(try f.snapshot(f.target.supportDirectory) == before)
    }

    @Test("C1.4c / C1.7 仅当前暂存可确认，取消与无标记启动会清理暂存")
    func tokens() async throws {
        let f = try ArchiveFixture()
        _ = try await f.export()
        let old = try await UserDataArchive.stage(f.zip, for: f.target, appValidators: appValidators)
        let new = try await UserDataArchive.stage(f.zip, for: f.target, appValidators: appValidators)
        #expect(old.token != new.token)
        #expect(throws: UserDataArchiveError.self) { try UserDataArchive.commitStaged(old, for: f.target) }
        #expect(await f.applyPendingImport() == nil)
        #expect(!manager.fileExists(atPath: f.staging.path))
        _ = try await f.stageAndCommit()
        UserDataArchive.discardStaged(for: f.target)
        #expect(!manager.fileExists(atPath: f.staging.path))
    }

    @Test("C1.6 移动中途出错后，已替换、已新增与 WAL 文件均恢复")
    func rollback() async throws {
        let f = try ArchiveFixture()
        try write(#"{"version":1,"value":{}}"#, UserDataItem.settings.url(in: f.source))
        try write(#"{"version":1,"value":["old"]}"#, UserDataItem.session.url(in: f.target))
        // 留下离线库及真实 WAL，关闭原连接不触动复制后的数据。
        do {
            let settings = try FileSettingsStore(directory: f.root)
            await settings.saveBookMemory(.init(book: .init(root: .local), lastPageIndex: 9))
            try await settings.flush()
            for suffix in ["", "-wal", "-shm"] {
                try manager.copyItem(at: f.root.appending(path: "state.sqlite" + suffix),
                                     to: f.target.supportDirectory.appending(path: "state.sqlite" + suffix))
            }
        }
        try manager.createDirectory(at: UserDataItem.scripts.url(in: f.source), withIntermediateDirectories: true)
        let old = try f.snapshot(f.target.supportDirectory)
        _ = try await f.export()
        try await f.stageAndCommit()
        let result = await UserDataArchive.applyPendingImport(for: f.target, origin: origin, appValidators: appValidators) { from, to, scratchID in
            if to == UserDataItem.scripts.url(in: f.target) { throw CocoaError(.fileWriteUnknown) }
            try UserDataArchive.move(from, to, scratchID)
        }
        guard case .rolledBack = result else { Issue.record("未回滚"); return }
        let actual = try f.snapshot(f.target.supportDirectory).filter { !$0.key.hasPrefix("Backups") }
        // SQLite 读取 WAL 时会更新共享内存的读标记。
        #expect(actual.filter { $0.key != "state.sqlite-shm" } == old.filter { $0.key != "state.sqlite-shm" })
        #expect(actual["state.sqlite-shm"] != nil)
    }

    @Test("C1.6b 外置布局的工作副本按记录清除，恢复可重跑，保留同目录其他文件", arguments: [false, true], [false, true])
    func layoutCopyInterrupted(committed: Bool, existedBefore: Bool) async throws {
        let f = try ArchiveFixture()
        let base = ProcessInfo.processInfo.environment["MV_ARCHIVE_TEST_LAYOUT_VOLUME"].map { URL(filePath: $0) } ?? f.root
        let external = base.appending(path: "layout-test-\(UUID())")
        try manager.createDirectory(at: external, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: external) }
        let target = UserDataLocations(supportDirectory: f.target.supportDirectory, layoutFile: external.appending(path: "layout"))
        if base != f.root {
            var supportInfo = stat(), volumeInfo = stat()
            #expect(stat(f.root.path, &supportInfo) == 0 && stat(external.path, &volumeInfo) == 0)
            #expect(supportInfo.st_dev != volumeInfo.st_dev)
        }
        let current = #"{"version":1,"value":["new"]}"#, original = #"{"version":1,"value":["old"]}"#
        try write(current, UserDataItem.layout.url(in: f.source))
        if existedBefore { try write(original, target.layoutFile) }
        _ = try await f.export()
        let staged = try await UserDataArchive.stage(f.zip, for: target, appValidators: appValidators)
        try UserDataArchive.commitStaged(staged, for: target)
        let applied = await UserDataArchive.applyPendingImport(for: target, origin: origin, appValidators: appValidators) { from, to, id in
            let bytes = try Data(contentsOf: target.rollback.appending(path: "journal.json"))
            let record = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            #expect(record?["layoutPath"] as? String == target.layoutFile.path)
            try UserDataArchive.move(from, to, id)
        }
        #expect(applied == .imported(staged.manifest, backup: UserDataArchive.backupURL(for: target)))
        #expect(try String(contentsOf: target.layoutFile, encoding: .utf8) == current)

        let id = UUID(), unrelated = external.appending(path: ".macview-move-\(UUID())")
        let partial = external.appending(path: ".macview-move-\(id)")
        try write("other", unrelated)
        try write("partial copy", partial)
        try manager.createDirectory(at: f.rollback, withIntermediateDirectories: false)
        if existedBefore { try write(original, f.rollback.appending(path: "layout.json")) }
        var existed = Dictionary(uniqueKeysWithValues: UserDataItem.allCases.map { ($0.rawValue, false) })
        existed["layout.json"] = existedBefore
        for db in [UserDataItem.bookMemory, .library] {
            for suffix in ["-wal", "-shm"] { existed[db.rawValue + suffix] = false }
        }
        let journal = try JSONSerialization.data(withJSONObject: [
            "state": committed ? "committed" : "applying", "existed": existed, "moveID": id.uuidString,
            "layoutPath": target.layoutFile.path,
        ])
        try journal.write(to: f.rollback.appending(path: "journal.json"))
        let newLayout = f.root.appending(path: "unrelated-layout")
        let restarted = UserDataLocations(supportDirectory: target.supportDirectory, layoutFile: newLayout)
        let unrelatedCopy = f.root.appending(path: ".macview-move-\(id)")
        try write("unrelated layout", newLayout)
        try write("unrelated copy", unrelatedCopy)
        let outcome = await UserDataArchive.applyPendingImport(for: restarted, origin: origin, appValidators: appValidators)
        switch (committed, outcome) {
        case (true, nil), (false, .rolledBack): break
        default: Issue.record("布局恢复结果与记录状态不符")
        }
        if committed || existedBefore {
            #expect(try String(contentsOf: target.layoutFile, encoding: .utf8) == (committed ? current : original))
        } else {
            #expect(!manager.fileExists(atPath: target.layoutFile.path))
        }
        #expect(try String(contentsOf: newLayout, encoding: .utf8) == "unrelated layout")
        #expect(try String(contentsOf: unrelatedCopy, encoding: .utf8) == "unrelated copy")
        #expect(!manager.fileExists(atPath: partial.path))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "other")
        #expect(await UserDataArchive.applyPendingImport(for: target, origin: origin, appValidators: appValidators) == nil)
    }

    enum Interruption: CaseIterable { case halfway, committed, halfRestored, cannotRecover, unknownLayout, legacyCleanup }
    @Test("C1.6b 崩溃恢复可重复，已提交只清理，无法恢复时保留现场和旧备份", arguments: Interruption.allCases)
    func interrupted(_ point: Interruption) async throws {
        let f = try ArchiveFixture()
        _ = try await f.export()
        try await f.stageAndCommit()
        try manager.createDirectory(at: f.rollback, withIntermediateDirectories: true)
        let backup = UserDataArchive.backupURL(for: f.target)
        try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("existing backup", backup)
        let journal = f.rollback.appending(path: "journal.json")
        var existed = Dictionary(uniqueKeysWithValues: UserDataItem.allCases.map { ($0.rawValue, false) })
        for item in [UserDataItem.library, .bookMemory] {
            for suffix in ["-wal", "-shm"] { existed[item.rawValue + suffix] = false }
        }
        existed["settings.json"] = true
        if point == .unknownLayout {
            existed["layout.json"] = true
            try write("old layout", f.rollback.appending(path: "layout.json"))
        }
        try write("unrelated", f.target.layoutFile)
        let legacyID = UUID()
        let unrelatedCopy = f.target.layoutFile.deletingLastPathComponent().appending(path: ".macview-move-\(legacyID)")
        try write("unrelated copy", unrelatedCopy)
        var record: [String: Any] = ["state": point == .committed ? "committed" : "applying", "existed": existed]
        if point == .committed { record["moveID"] = legacyID.uuidString }
        if point == .legacyCleanup {
            record["layoutOmitted"] = true
            try manager.removeItem(at: f.staging)
        }
        let bytes = try JSONSerialization.data(withJSONObject: record)
        try bytes.write(to: journal)
        let settings = UserDataItem.settings.url(in: f.target)
        let menus = UserDataItem.menus.url(in: f.target)
        try write("new", menus)
        switch point {
        case .halfway, .committed, .unknownLayout:
            try write("old", f.rollback.appending(path: "settings.json"))
            try write("new", settings)
        case .halfRestored, .legacyCleanup: try write("old", settings)
        case .cannotRecover: break
        }
        let before = try f.snapshot(f.target.supportDirectory)
        let result = await f.applyPendingImport()
        switch point {
        case .cannotRecover, .unknownLayout:
            guard case .recoveryFailed = result else { Issue.record("未报告恢复失败"); return }
            #expect(try before == f.snapshot(f.target.supportDirectory))
        case .committed:
            #expect(result == nil)
            #expect(try String(contentsOf: settings, encoding: .utf8) == "new")
            #expect(manager.fileExists(atPath: menus.path))
        case .halfway, .halfRestored, .legacyCleanup:
            guard case .rolledBack = result else { Issue.record("未完成恢复"); return }
            #expect(try String(contentsOf: settings, encoding: .utf8) == "old")
            #expect(!manager.fileExists(atPath: menus.path))
        }
        if point != .cannotRecover, point != .unknownLayout {
            #expect(!manager.fileExists(atPath: f.staging.path) && !manager.fileExists(atPath: f.rollback.path))
            #expect(await f.applyPendingImport() == nil)
        }
        #expect(try String(contentsOf: f.target.layoutFile, encoding: .utf8) == "unrelated")
        #expect(try String(contentsOf: unrelatedCopy, encoding: .utf8) == "unrelated copy")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "existing backup")
    }
}
