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

@Test func manifestParsesPanelDeclarationsAndOptionalFields() throws {
    // C1.1: 合法面板清单解析出全部字段；省略 symbol、defaultEdge 时为 nil
    let json = """
    {
      "name": "页面笔记",
      "version": "1.0.0",
      "permissions": ["commands"],
      "panels": [
        {
          "id": "notes",
          "title": "页面笔记",
          "entry": "panel.html",
          "symbol": "note.text",
          "defaultEdge": "right"
        },
        {
          "id": "sub-panel-2",
          "title": "辅助面板",
          "entry": "web/index.html"
        }
      ]
    }
    """
    let result = PluginManifest.parse(data: Data(json.utf8))
    guard case let .success(manifest) = result else {
        Issue.record("预期合法面板清单解析成功，实际失败：\(result)")
        return
    }
    #expect(manifest.runtime == nil)
    #expect(manifest.permissions == [.commands])
    #expect(manifest.panels == [
        PluginPanelDeclaration(id: "notes", title: "页面笔记", entry: "panel.html", symbol: "note.text", defaultEdge: .right),
        PluginPanelDeclaration(id: "sub-panel-2", title: "辅助面板", entry: "web/index.html", symbol: nil, defaultEdge: nil),
    ])
}

@Test func manifestRuntimeRequirementWithAndWithoutPanels() throws {
    // C1.2: 只有面板、没有 runtime 的清单有效
    let panelsOnly = #"{"name":"Panels","version":"1.0","panels":[{"id":"p1","title":"P1","entry":"index.html"}]}"#
    if case let .success(manifest) = PluginManifest.parse(data: Data(panelsOnly.utf8)) {
        #expect(manifest.runtime == nil)
        #expect(manifest.panels.count == 1)
    } else {
        Issue.record("只有面板、没有 runtime 的清单应有效")
    }

    // 有 commands 而没有 runtime 报「缺少必填字段 runtime」
    let commandsNoRuntime = #"{"name":"Cmd","version":"1.0","commands":[{"id":"c1","title":"C1"}],"panels":[{"id":"p1","title":"P1","entry":"index.html"}]}"#
    if case let .failure(problem) = PluginManifest.parse(data: Data(commandsNoRuntime.utf8)) {
        #expect(problem.message == "缺少必填字段 runtime")
    } else {
        Issue.record("有 commands 而没有 runtime 应报错")
    }

    // 有 events / sources / filters 而没有 runtime 也报「缺少必填字段 runtime」
    for snippet in [
        #"{"name":"E","version":"1.0","events":["pageChanged"],"panels":[{"id":"p1","title":"P1","entry":"index.html"}]}"#,
        #"{"name":"S","version":"1.0","sources":[{"id":"s1","name":"S1"}],"panels":[{"id":"p1","title":"P1","entry":"index.html"}]}"#,
        #"{"name":"F","version":"1.0","filters":[{"id":"f1","name":"F1"}],"panels":[{"id":"p1","title":"P1","entry":"index.html"}]}"#,
    ] {
        if case let .failure(problem) = PluginManifest.parse(data: Data(snippet.utf8)) {
            #expect(problem.message == "缺少必填字段 runtime")
        } else {
            Issue.record("缺少 runtime 应报错：\(snippet)")
        }
    }

    // 既没有 runtime 也没有 panels 也报「缺少必填字段 runtime」
    let neither = #"{"name":"Empty","version":"1.0"}"#
    if case let .failure(problem) = PluginManifest.parse(data: Data(neither.utf8)) {
        #expect(problem.message == "缺少必填字段 runtime")
    } else {
        Issue.record("既没有 runtime 也没有 panels 应报错")
    }
}

@Test func manifestRejectsInvalidPanelsWithLocation() throws {
    // C1.3: id 不合规、重复、title 为空、entry 为空/绝对路径/含 ..、defaultEdge 非法
    let cases: [(label: String, json: String, expectedLine: Int)] = [
        ("id 不合规", """
        {
          "name": "P",
          "version": "1.0",
          "panels": [
            { "id": "Bad_ID", "title": "T", "entry": "a.html" }
          ]
        }
        """, 5),
        ("id 重复", """
        {
          "name": "P",
          "version": "1.0",
          "panels": [
            { "id": "dup", "title": "T1", "entry": "a.html" },
            { "id": "dup", "title": "T2", "entry": "b.html" }
          ]
        }
        """, 5),
        ("title 为空", """
        {
          "name": "P",
          "version": "1.0",
          "panels": [
            { "id": "ok", "title": "", "entry": "a.html" }
          ]
        }
        """, 5),
        ("entry 为空", """
        {
          "name": "P",
          "version": "1.0",
          "panels": [
            { "id": "ok", "title": "T", "entry": "" }
          ]
        }
        """, 5),
        ("entry 绝对路径", """
        {
          "name": "P",
          "version": "1.0",
          "panels": [
            { "id": "ok", "title": "T", "entry": "/etc/passwd" }
          ]
        }
        """, 5),
        ("entry 含 .. 段", """
        {
          "name": "P",
          "version": "1.0",
          "panels": [
            { "id": "ok", "title": "T", "entry": "web/../secret.html" }
          ]
        }
        """, 5),
        ("defaultEdge 非法", """
        {
          "name": "P",
          "version": "1.0",
          "panels": [
            { "id": "ok", "title": "T", "entry": "a.html", "defaultEdge": "top" }
          ]
        }
        """, 5),
    ]
    for item in cases {
        let result = PluginManifest.parse(data: Data(item.json.utf8))
        guard case let .failure(problem) = result else {
            Issue.record("\(item.label) 应报错")
            continue
        }
        #expect(problem.file == "manifest.json")
        #expect(problem.line == item.expectedLine)
        #expect((problem.column ?? 0) > 0)
    }
}

@Test func libraryValidatesPanelEntryFileExistence() async throws {
    // C1.4: 入口文件不存在时插件带问题、manifest 为 nil；在子文件夹里存在时有效
    let root = try tempDir("panel-entries")
    defer { try? FileManager.default.removeItem(at: root) }

    // 缺少入口文件的插件
    let missingDir = root.appendingPathComponent("missing-entry")
    try FileManager.default.createDirectory(at: missingDir, withIntermediateDirectories: true)
    try """
    {
      "name": "Missing",
      "version": "1.0",
      "panels": [
        { "id": "notes", "title": "笔记", "entry": "panel.html" }
      ]
    }
    """.write(to: missingDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    // 入口指向目录而不是普通文件
    let dirEntryPlugin = root.appendingPathComponent("dir-entry")
    try FileManager.default.createDirectory(at: dirEntryPlugin.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try """
    {
      "name": "DirEntry",
      "version": "1.0",
      "panels": [
        { "id": "notes", "title": "笔记", "entry": "sub" }
      ]
    }
    """.write(to: dirEntryPlugin.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    // 入口文件存在于子文件夹中
    let nestedDir = root.appendingPathComponent("nested-entry")
    try FileManager.default.createDirectory(at: nestedDir.appendingPathComponent("web"), withIntermediateDirectories: true)
    try """
    {
      "name": "Nested",
      "version": "1.0",
      "panels": [
        { "id": "notes", "title": "笔记", "entry": "web/index.html" }
      ]
    }
    """.write(to: nestedDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try "<html></html>".write(to: nestedDir.appendingPathComponent("web/index.html"), atomically: true, encoding: .utf8)

    let library = PluginLibrary(directory: root)
    #expect(await waitUntil { library.plugins().count == 3 })

    let missing = try #require(library.plugins().first { $0.id == "missing-entry" })
    #expect(missing.manifest == nil)
    #expect(missing.problem?.file == "manifest.json")
    #expect(missing.problem?.line == 5)
    #expect((missing.problem?.column ?? 0) > 0)

    let dirEntry = try #require(library.plugins().first { $0.id == "dir-entry" })
    #expect(dirEntry.manifest == nil)
    #expect(dirEntry.problem?.file == "manifest.json")

    let nested = try #require(library.plugins().first { $0.id == "nested-entry" })
    #expect(nested.problem == nil)
    #expect(nested.manifest?.panels.first?.entry == "web/index.html")
}
