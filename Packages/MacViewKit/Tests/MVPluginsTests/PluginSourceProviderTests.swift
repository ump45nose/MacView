import Foundation
import MVArchive
import MVFoundation
import MVIO
import MVScripting
import MVSettings
import Testing
@testable import MVPlugins

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func waitUntil(timeout: Duration = .seconds(3), _ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            while !Task.isCancelled {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        group.addTask { try? await Task.sleep(for: timeout); return false }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private final class WebDAVServerHandle {
    let process: Process
    let baseURL: String
    let port: Int

    init(root: URL, port: Int = 0, user: String, password: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [
            repoRootURL().appendingPathComponent("scripts/webdav-test-server.py").path,
            "--root", root.path,
            "--port", String(port),
            "--user", user,
            "--password", password,
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        self.process = proc

        var line = Data()
        while true {
            let chunk = try pipe.fileHandleForReading.read(upToCount: 1) ?? Data()
            if chunk.isEmpty { break }
            if chunk[0] == 0x0A { break }
            line.append(chunk)
        }
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("READY "), let url = URL(string: String(text.dropFirst(6))), let boundPort = url.port else {
            proc.terminate()
            throw NSError(domain: "WebDAVServerHandle", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试服务启动失败：\(text)"])
        }
        self.baseURL = url.absoluteString
        self.port = boundPort
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    deinit {
        stop()
    }
}

/// 生成一个包含一个 stored 文件的小型 zip 归档，用于测试远端目录中的压缩包浏览。
private func makeTestZip(entryName: String, payload: Data, to destination: URL) throws {
    let tmpDir = destination.deletingLastPathComponent().appendingPathComponent("zip-src-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try payload.write(to: tmpDir.appendingPathComponent(entryName))
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    proc.currentDirectoryURL = tmpDir
    proc.arguments = ["-q", destination.path, entryName]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        throw NSError(domain: "makeTestZip", code: Int(proc.terminationStatus))
    }
}

private func collectEntries(_ stream: AsyncThrowingStream<[Entry], any Error>) async throws -> [Entry] {
    var result: [Entry] = []
    for try await batch in stream { result.append(contentsOf: batch) }
    return result
}

@Test func webdavSourceListRangeArchiveColdStartDisableReenableAndServerRecovery() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/MVPluginsSourceTests/webdav-\(UUID().uuidString)")
    let davRoot = root.appendingPathComponent("dav-root")
    let subDir = davRoot.appendingPathComponent("album")
    let pluginsDir = root.appendingPathComponent("Plugins")
    let extractDir = root.appendingPathComponent("extract")
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 准备测试数据：子目录中的图片与压缩包
    let samplePayload = Data((0..<4096).map { UInt8($0 & 0xFF) })
    try samplePayload.write(to: subDir.appendingPathComponent("page1.jpg"))
    let zipInnerBytes = Data("PNG-INNER-TEST-CONTENT-1234567890".utf8)
    try makeTestZip(entryName: "001.png", payload: zipInnerBytes, to: davRoot.appendingPathComponent("comic.zip"))

    // 安装 WebDAV 示例插件
    try FileManager.default.copyItem(
        at: repoRootURL().appendingPathComponent("Examples/Plugins/webdav"),
        to: pluginsDir.appendingPathComponent("webdav")
    )

    let server = try WebDAVServerHandle(root: davRoot, port: 0, user: "tester", password: "pw-secret")
    let boundPort = server.port
    let baseURL = server.baseURL
    defer { server.stop() }

    let settings = try JSONDocumentStore(fileURL: root.appendingPathComponent("plugins.json"), version: 1, defaultValue: PluginSettingsFile())
    let secrets = try PluginSecrets(fileURL: root.appendingPathComponent("plugin-secrets.json"))
    let log = ScriptLog()
    let sourceID = UUID()
    try await settings.update { file in
        file.plugins["webdav"] = PluginState(enabled: true, grantedPermissions: [])
        file.sources = [SourceInstance(
            id: sourceID,
            plugin: "webdav",
            type: "webdav",
            name: "Local DAV",
            values: ["url": baseURL, "user": "tester"]
        )]
    }
    try await secrets.set(["password": "pw-secret"], for: sourceID)

    let library = PluginLibrary(directory: pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "webdav" } })

    let config = PluginHostConfiguration(
        pythonLibraryDirectory: repoRootURL().appendingPathComponent("PluginSupport/python"),
        supportDirectory: root,
        requestTimeout: .seconds(5)
    )
    let host = PluginHost(library: library, settings: settings, secrets: secrets, log: log, configuration: config)
    defer { host.shutdown() }

    let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
    defer { scheduler.shutdown() }
    let registry = FileSourceRegistry(scheduler: scheduler)
    let extracts = try ExtractStore(directory: extractDir)
    let pluginProvider = PluginSourceProvider(host: host, extracts: extracts, requestTimeout: 3)
    let archiveProvider = ArchiveProvider(fileSystem: registry.fileSystem, extracts: extracts) { location in
        if PluginSourceProvider.sourceID(of: location.root) != nil { return pluginProvider }
        return registry.fileSystem
    }
    registry.register(archiveProvider)
    registry.register(pluginProvider)

    let sourceRoot = Location(root: PluginSourceProvider.root(for: sourceID), layers: [[]])

    // C1.12：列根目录、列子目录、按 Range 读字节与原文件一致
    let rootEntries = try await collectEntries(try registry.provider(for: sourceRoot).children(of: sourceRoot, priority: .visible))
    #expect(Set(rootEntries.map(\.name)) == ["album", "comic.zip"])
    let albumLoc = sourceRoot.appending("album")
    let subEntries = try await collectEntries(try registry.provider(for: albumLoc).children(of: albumLoc, priority: .visible))
    #expect(subEntries.map(\.name) == ["page1.jpg"])
    #expect(subEntries[0].kind == .image)
    #expect(subEntries[0].identity.checksum != nil)

    let pageLoc = albumLoc.appending("page1.jpg")
    let byteSource = try await registry.provider(for: pageLoc).open(pageLoc)
    let slice = try await byteSource.read(100..<612, priority: .visible, group: nil)
    #expect(slice == samplePayload[100..<612])

    // fileLease 可下载到共享 ExtractStore
    let lease = try await registry.provider(for: pageLoc).fileLease(for: pageLoc)
    #expect(try Data(contentsOf: lease.url) == samplePayload)

    // C1.13：远端目录里的 zip 能列出内页并读出图片
    let zipLoc = sourceRoot.appending("comic.zip")
    let zipProvider = try registry.provider(for: zipLoc)
    let zipEntries = try await collectEntries(zipProvider.children(of: zipLoc, priority: .visible))
    #expect(zipEntries.map(\.name) == ["001.png"])
    let innerLoc = zipEntries[0].location
    let innerSource = try await registry.provider(for: innerLoc).open(innerLoc)
    let innerRead = try await innerSource.read(0..<Int64(zipInnerBytes.count), priority: .visible, group: nil)
    #expect(innerRead == zipInnerBytes)

    // C1.16b：新建冷启动 PluginSourceProvider（内存表为空），直接 open 某页先回填父目录再读出正确字节
    let coldProvider = PluginSourceProvider(host: host, extracts: extracts, requestTimeout: 3)
    let coldSource = try await coldProvider.open(pageLoc)
    let coldBytes = try await coldSource.read(0..<256, priority: .visible, group: nil)
    #expect(coldBytes == samplePayload[0..<256])

    // C1.14：停掉服务后 children 与 open/read 在时限内抛错不挂起；重启服务后重试成功
    server.stop()
    do {
        _ = try await collectEntries(pluginProvider.children(of: sourceRoot, priority: .visible))
        Issue.record("停服后 children 应抛错")
    } catch {
        // 预期抛错
    }
    do {
        _ = try await byteSource.read(0..<64, priority: .visible, group: nil)
        Issue.record("停服后 read 应抛错")
    } catch {
        // 预期抛错
    }

    let restarted = try WebDAVServerHandle(root: davRoot, port: boundPort, user: "tester", password: "pw-secret")
    defer { restarted.stop() }
    let recoveredEntries = try await collectEntries(pluginProvider.children(of: sourceRoot, priority: .visible))
    #expect(Set(recoveredEntries.map(\.name)) == ["album", "comic.zip"])
    let recoveredSlice = try await byteSource.read(0..<64, priority: .visible, group: nil)
    #expect(recoveredSlice == samplePayload[0..<64])

    // C1.15：插件停用后该根抛 IOError.volumeUnavailable
    try await settings.update { $0.plugins["webdav"]?.enabled = false }
    do {
        _ = try await collectEntries(pluginProvider.children(of: sourceRoot, priority: .visible))
        Issue.record("插件停用后应抛 volumeUnavailable")
    } catch let error as IOError {
        #expect(error == .volumeUnavailable(sourceRoot.root))
    }

    // C1.16c：重新启用插件后该根恢复可读
    try await settings.update { $0.plugins["webdav"]?.enabled = true }
    let afterReenable = try await collectEntries(pluginProvider.children(of: sourceRoot, priority: .visible))
    #expect(Set(afterReenable.map(\.name)) == ["album", "comic.zip"])

    // C1.15（来源删除）：删除来源实例后抛 IOError.volumeUnavailable
    try await settings.update { $0.sources.removeAll() }
    do {
        _ = try await pluginProvider.open(pageLoc)
        Issue.record("删除来源后应抛 volumeUnavailable")
    } catch let error as IOError {
        #expect(error == .volumeUnavailable(sourceRoot.root))
    }
}

@Test func wikimediaPluginListsDirectURLsFromStubHTTP() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/MVPluginsSourceTests/wikimedia-\(UUID().uuidString)")
    let pluginsDir = root.appendingPathComponent("Plugins")
    let extractDir = root.appendingPathComponent("extract")
    try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.copyItem(
        at: repoRootURL().appendingPathComponent("Examples/Plugins/wikimedia-commons"),
        to: pluginsDir.appendingPathComponent("wikimedia-commons")
    )

    let settings = try JSONDocumentStore(fileURL: root.appendingPathComponent("plugins.json"), version: 1, defaultValue: PluginSettingsFile())
    let secrets = try PluginSecrets(fileURL: root.appendingPathComponent("plugin-secrets.json"))
    let log = ScriptLog()
    let sourceID = UUID()
    try await settings.update { file in
        file.plugins["wikimedia-commons"] = PluginState(enabled: true, grantedPermissions: [.network])
        file.sources = [SourceInstance(
            id: sourceID,
            plugin: "wikimedia-commons",
            type: "wikimedia",
            name: "Cats",
            values: ["query": "cat"]
        )]
    }

    let library = PluginLibrary(directory: pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "wikimedia-commons" } })

    let stubJSON = """
    {
      "query": {
        "pages": {
          "101": {
            "title": "File:Tabby_cat.jpg",
            "imageinfo": [{
              "url": "https://upload.wikimedia.org/wikipedia/commons/a/ab/Tabby_cat.jpg",
              "size": 123456,
              "timestamp": "2025-01-02T03:04:05Z",
              "sha1": "deadbeef1234"
            }]
          }
        }
      }
    }
    """

    let config = PluginHostConfiguration(
        supportDirectory: root,
        httpHandler: { request in
            #expect(request.url.contains("gsrsearch=cat"))
            #expect(request.headers["User-Agent"]?.contains("MacView") == true)
            return PluginHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: stubJSON)
        }
    )
    let host = PluginHost(library: library, settings: settings, secrets: secrets, log: log, configuration: config)
    defer { host.shutdown() }

    let extracts = try ExtractStore(directory: extractDir)
    let provider = PluginSourceProvider(host: host, extracts: extracts)
    let sourceRoot = Location(root: PluginSourceProvider.root(for: sourceID), layers: [[]])

    let entries = try await collectEntries(provider.children(of: sourceRoot, priority: .visible))
    #expect(entries.count == 1)
    #expect(entries[0].name == "Tabby_cat.jpg")
    #expect(entries[0].kind == .image)
    #expect(entries[0].size == 123456)
    #expect(entries[0].identity.checksum != nil)

    let byteSource = try await provider.open(entries[0].location)
    let httpSource = try #require(byteSource as? HTTPByteSource)
    #expect(httpSource.url.absoluteString == "https://upload.wikimedia.org/wikipedia/commons/a/ab/Tabby_cat.jpg")
    #expect(httpSource.headers["User-Agent"]?.contains("MacView") == true)
}
