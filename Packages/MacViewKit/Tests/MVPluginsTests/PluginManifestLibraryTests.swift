import Darwin
import Foundation
import MVFoundation
import MVScripting
import MVSettings
import Testing
@testable import MVPlugins

private func tempDir(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/MVPluginsTests/\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool, timeout: Duration = .seconds(2)) async -> Bool {
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

@Test func manifestParsesAllFields() throws {
    let json = """
    {
      "name": "WebDAV",
      "version": "1.0",
      "description": "浏览 WebDAV 服务器上的图片",
      "runtime": { "process": { "command": "/usr/bin/python3", "args": ["main.py"] } },
      "permissions": ["network"],
      "commands": [{ "id": "random", "title": "随机跳页" }],
      "events": ["pageChanged", "bookOpened"],
      "sources": [{
        "id": "webdav", "name": "WebDAV",
        "fields": [
          { "key": "url", "label": "地址", "type": "url", "required": true },
          { "key": "user", "label": "账号", "type": "text" },
          { "key": "password", "label": "密码", "type": "password" }
        ]
      }],
      "filters": [{
        "id": "gray", "name": "灰度",
        "parameters": [
          { "key": "scale", "label": "倍数", "type": "choice", "options": ["2", "4"], "default": "2" },
          { "key": "strength", "label": "强度", "type": "number", "min": 0, "max": 1, "step": 0.1, "default": 0.5 },
          { "key": "invert", "label": "反转", "type": "bool", "default": false }
        ]
      }]
    }
    """
    let result = PluginManifest.parse(data: Data(json.utf8))
    guard case let .success(manifest) = result else {
        Issue.record("预期合法清单解析成功，实际失败：\(result)")
        return
    }
    #expect(manifest.name == "WebDAV")
    #expect(manifest.version == "1.0")
    #expect(manifest.description == "浏览 WebDAV 服务器上的图片")
    #expect(manifest.runtime == .process(command: "/usr/bin/python3", arguments: ["main.py"]))
    #expect(manifest.permissions == [.network])
    #expect(manifest.commands == [PluginCommandDeclaration(id: "random", title: "随机跳页")])
    #expect(manifest.events == [.pageChanged, .bookOpened])
    #expect(manifest.sources.count == 1)
    #expect(manifest.sources[0].fields.count == 3)
    #expect(manifest.sources[0].fields[0].required == true)
    #expect(manifest.sources[0].passwordFieldKeys == ["password"])
    #expect(manifest.filters.count == 1)
    #expect(manifest.filters[0].parameters.count == 3)
    #expect(manifest.filters[0].parameters[0].defaultValue == .string("2"))
}

@Test func manifestRejectsInvalidCasesWithLocation() throws {
    // 缺必填字段
    let missingName = #"{"version":"1.0","runtime":{"js":"main.js"}}"#
    if case let .failure(problem) = PluginManifest.parse(data: Data(missingName.utf8)) {
        #expect(problem.file == "manifest.json")
        #expect(problem.line != nil && problem.column != nil)
    } else { Issue.record("缺 name 应报错") }

    // 类型错误
    let wrongType = """
    {
      "name": "Demo",
      "version": 123,
      "runtime": { "js": "main.js" }
    }
    """
    if case let .failure(problem) = PluginManifest.parse(data: Data(wrongType.utf8)) {
        #expect(problem.file == "manifest.json")
        #expect(problem.line == 3)
        #expect((problem.column ?? 0) > 0)
    } else { Issue.record("version 非字符串应报错") }

    // JS 插件声明 filters
    let jsWithFilter = """
    {
      "name": "BadJS",
      "version": "1.0",
      "runtime": { "js": "main.js" },
      "filters": [{ "id": "gray", "name": "灰度" }]
    }
    """
    if case let .failure(problem) = PluginManifest.parse(data: Data(jsWithFilter.utf8)) {
        #expect(problem.file == "manifest.json")
        #expect(problem.line == 5)
        #expect(problem.message.contains("JS"))
    } else { Issue.record("JS 插件声明 filters 应报错") }

    // JSON 语法错
    let badJSON = "{\n  \"name\": \"Broken\",\n  \"version\": \n}"
    if case let .failure(problem) = PluginManifest.parse(data: Data(badJSON.utf8)) {
        #expect(problem.file == "manifest.json")
        #expect(problem.line != nil && problem.column != nil)
    } else { Issue.record("非法 JSON 应报错") }

    // ID 校验
    #expect(PluginManifest.isValidPluginID("webdav"))
    #expect(PluginManifest.isValidPluginID("wikimedia-commons-2"))
    #expect(!PluginManifest.isValidPluginID("Bad_ID"))
    #expect(!PluginManifest.isValidPluginID("-leading"))
    #expect(!PluginManifest.isValidPluginID("UPPER"))
}

@Test func libraryWatchesAddModifyDeleteAndInvalidFolderID() async throws {
    let root = try tempDir("library")
    defer { try? FileManager.default.removeItem(at: root) }

    let invalidDir = root.appendingPathComponent("Bad_Plugin")
    try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
    try #"{"name":"Bad","version":"1.0","runtime":{"js":"main.js"}}"#.write(
        to: invalidDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8
    )

    let library = PluginLibrary(directory: root)
    #expect(await waitUntil { library.plugins().count == 1 })
    let bad = try #require(library.plugins().first { $0.id == "Bad_Plugin" })
    #expect(bad.manifest == nil)
    #expect(bad.problem?.file == "manifest.json")
    #expect(bad.problem?.line != nil && bad.problem?.column != nil)

    // 新增插件文件夹
    let demoDir = root.appendingPathComponent("demo-plugin")
    try FileManager.default.createDirectory(at: demoDir, withIntermediateDirectories: true)
    try #"{"name":"Demo V1","version":"1.0","runtime":{"js":"main.js"}}"#.write(
        to: demoDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8
    )
    #expect(await waitUntil { library.plugins().contains { $0.id == "demo-plugin" && $0.manifest?.name == "Demo V1" } })

    // 修改清单
    try #"{"name":"Demo V2","version":"2.0","runtime":{"js":"main.js"}}"#.write(
        to: demoDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8
    )
    #expect(await waitUntil { library.plugins().contains { $0.id == "demo-plugin" && $0.manifest?.name == "Demo V2" } })

    // 删除插件文件夹
    try FileManager.default.removeItem(at: demoDir)
    #expect(await waitUntil { !library.plugins().contains { $0.id == "demo-plugin" } })
}

@Test func pluginStatusNeedsConsentWhenPermissionsGrow() throws {
    let manifest = PluginManifest(name: "Net", version: "1.0", runtime: .javascript(entry: "main.js"), permissions: [.network, .commands])
    let info = PluginInfo(id: "net", directory: URL(fileURLWithPath: "/tmp/net"), manifest: manifest, problem: nil)
    #expect(PluginStatus.evaluate(info: info, state: nil) == .disabled)
    #expect(PluginStatus.evaluate(info: info, state: PluginState(enabled: false, grantedPermissions: [.network, .commands])) == .disabled)
    #expect(PluginStatus.evaluate(info: info, state: PluginState(enabled: true, grantedPermissions: [.network])) == .needsConsent)
    #expect(PluginStatus.evaluate(info: info, state: PluginState(enabled: true, grantedPermissions: [.network, .commands])) == .ready)
    let since = Date()
    #expect(PluginStatus.evaluate(info: info, state: PluginState(enabled: true, grantedPermissions: [.network, .commands]), runningSince: since) == .running(since: since))
    #expect(PluginStatus.evaluate(info: info, state: PluginState(enabled: true, grantedPermissions: [.network, .commands]), failure: "boom") == .failed("boom"))
}

@Test func secretsUse600PermissionsAndStayOutOfPluginsJSON() async throws {
    let dir = try tempDir("secrets")
    defer { try? FileManager.default.removeItem(at: dir) }

    let secretsURL = dir.appendingPathComponent("plugin-secrets.json")
    let settingsURL = dir.appendingPathComponent("plugins.json")
    let secrets = try PluginSecrets(fileURL: secretsURL)
    let settings = try JSONDocumentStore(fileURL: settingsURL, version: 1, defaultValue: PluginSettingsFile())

    let sourceDecl = PluginSourceDeclaration(id: "webdav", name: "WebDAV", fields: [
        PluginFieldDeclaration(key: "url", label: "地址", type: .url, required: true),
        PluginFieldDeclaration(key: "user", label: "账号", type: .text),
        PluginFieldDeclaration(key: "password", label: "密码", type: .password),
    ])
    let (pub, sec) = SourceInstance.partitionValues([
        "url": "http://127.0.0.1:8080/",
        "user": "alice",
        "password": "super-secret-value-999",
    ], declaration: sourceDecl)

    let id = UUID()
    try await settings.update { file in
        file.sources.append(SourceInstance(id: id, plugin: "webdav", type: "webdav", name: "Test", values: pub))
    }
    try await secrets.set(sec, for: id)

    // 检查 plugin-secrets.json 权限为 0600
    var st = stat()
    #expect(stat(secretsURL.path, &st) == 0)
    #expect((st.st_mode & 0o777) == 0o600)

    // 放宽权限后重新初始化，应自动修正回 0600
    #expect(chmod(secretsURL.path, 0o644) == 0)
    let reloadedSecrets = try PluginSecrets(fileURL: secretsURL)
    #expect(stat(secretsURL.path, &st) == 0)
    #expect((st.st_mode & 0o777) == 0o600)
    #expect(reloadedSecrets.values(for: id)["password"] == "super-secret-value-999")

    // plugins.json 中不得出现密码字段值
    let pluginsText = try String(contentsOf: settingsURL, encoding: .utf8)
    #expect(!pluginsText.contains("super-secret-value-999"))
    #expect(pluginsText.contains("alice"))

    // 删除密码
    try await reloadedSecrets.remove(source: id)
    #expect(reloadedSecrets.values(for: id).isEmpty)
}

@Test func bundledExampleManifestsAllParseCleanly() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // MVPluginsTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // MacViewKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
    for name in ["webdav", "wikimedia-commons", "grayscale", "random-page"] {
        #expect(PluginManifest.isValidPluginID(name))
        let url = repoRoot.appendingPathComponent("Examples/Plugins/\(name)/manifest.json")
        let data = try Data(contentsOf: url)
        let result = PluginManifest.parse(data: data, file: "manifest.json")
        if case let .failure(problem) = result {
            Issue.record("示例插件 \(name) 清单解析失败：\(problem)")
        }
    }
}
