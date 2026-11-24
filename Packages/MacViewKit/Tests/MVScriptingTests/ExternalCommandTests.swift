import Darwin
import Foundation
import Testing
@testable import MVScripting

private let templateValues = TemplateValues(files: ["/tmp/A B/a's.png", "/tmp/中文.png"], book: "book's $x", page: 7)

@Test func programTemplateArguments() throws {
    let args = try CommandTemplate.programArguments("--out=\"{folder}/x\" '{name}' {files} {book} {page} x\\ y ''", values: templateValues)
    #expect(args == ["--out=/tmp/A B/x", "a's.png", "/tmp/A B/a's.png", "/tmp/中文.png", "book's $x", "7", "x y", ""])
    #expect(throws: (any Error).self) { try CommandTemplate.programArguments("'unclosed", values: templateValues) }
    #expect(try CommandTemplate.programArguments("{files}", values: TemplateValues(files: [], book: nil, page: nil)).isEmpty)
}

@Test func shellTemplateEscapesValues() async throws {
    let values = TemplateValues(files: ["空 格 '$HOME `echo x`\n第二行"], book: nil, page: nil)
    let command = CommandTemplate.shellCommand("printf %s {file}", values: values)
    let result = try await ProcessRunner().run(executable: "/bin/sh", arguments: ["-c", command], workingDirectory: nil)
    #expect(result.exitCode == 0)
    #expect(result.stdout == values.files[0])
    for template in ["printf %s \"{file}\"", "printf %s '{file}'", "printf %s prefix\"{file}\"suffix"] {
        let expanded = CommandTemplate.shellCommand(template, values: values)
        let actual = try await ProcessRunner().run(executable: "/bin/sh", arguments: ["-c", expanded], workingDirectory: nil)
        let expected = template.contains("prefix") ? "prefix" + values.files[0] + "suffix" : values.files[0]
        #expect(actual.exitCode == 0 && actual.stdout == expected)
    }
    #expect(CommandTemplate.placeholders == ["{file}", "{files}", "{folder}", "{name}", "{book}", "{page}"])
}

@Test func externalCommandDecodingDefaults() throws {
    let data = Data(#"{"commands":[{"id":"one","name":"测试","kind":"program","program":"/bin/echo","arguments":"{files}"}]}"#.utf8)
    let file = try JSONDecoder().decode(ExternalCommandFile.self, from: data)
    #expect(file.commands.count == 1)
    #expect(file.commands[0].showOutput == false)
    #expect(file.commands[0].workingDirectory == nil)
    #expect(try JSONDecoder().decode(ExternalCommandFile.self, from: JSONEncoder().encode(file)) == file)
}

@Test func processOutputsAndMissingExecutable() async throws {
    let runner = ProcessRunner()
    let result = try await runner.run(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 7"], workingDirectory: nil)
    #expect(result.exitCode == 7); #expect(result.stdout == "out"); #expect(result.stderr == "err")
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let whereAmI = try await runner.run(executable: "/bin/pwd", arguments: [], workingDirectory: cwd.path)
    #expect(whereAmI.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == cwd.path)
    let large = try await runner.run(executable: "/bin/sh", arguments: ["-c", "head -c 70000 /dev/zero | tr '\\0' x; printf END; head -c 70000 /dev/zero | tr '\\0' y >&2; printf FIN >&2"], workingDirectory: nil)
    #expect(large.stdout.utf8.count == 65536 && large.stdout.hasSuffix("END"))
    #expect(large.stderr.utf8.count == 65536 && large.stderr.hasSuffix("FIN"))
    do { _ = try await runner.run(executable: "/this/program/does/not/exist", arguments: [], workingDirectory: nil); Issue.record("缺失程序没有报错") }
    catch { #expect(error.localizedDescription.contains("/this/program/does/not/exist")) }
}

@Test func processLoginShell() async throws {
    let runner = ProcessRunner()
    let result = try await runner.runShell("printf login-shell", workingDirectory: nil)
    #expect(result.exitCode == 0 && result.stdout == "login-shell")
    if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/brew") {
        let brew = try await runner.runShell("command -v brew", workingDirectory: nil)
        #expect(brew.exitCode == 0 && brew.stdout.contains("brew"))
    }
}

@Test func processCancellationKillsGroup() async throws {
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/MVScriptingProcessTests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("pids")
    let script = "trap '' TERM; echo $$ > '$1'; sleep 100 & echo $! >> '$1'; sleep 100 & echo $! >> '$1'; wait".replacingOccurrences(of: "'$1'", with: "\"$1\"")
    let task = Task { try await ProcessRunner().run(executable: "/bin/sh", arguments: ["-c", script, "sh", file.path], workingDirectory: nil) }
    var pids: [pid_t] = []
    for _ in 0..<100 {
        if let data = try? String(contentsOf: file, encoding: .utf8) { pids = data.split(whereSeparator: \.isNewline).compactMap { pid_t($0) } }
        if pids.count == 3 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(pids.count == 3)
    task.cancel()
    do { _ = try await task.value; Issue.record("取消未抛错") } catch is CancellationError {} catch { Issue.record("错误类型：\(error)") }
    for _ in 0..<100 {
        if pids.allSatisfy({ Darwin.kill($0, 0) != 0 && errno == ESRCH }) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(pids.allSatisfy { Darwin.kill($0, 0) != 0 && errno == ESRCH })
}
