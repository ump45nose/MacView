import AppKit
import Foundation
import MVFoundation
import MVIO
import MVScripting
import MVServices

/// 执行三类外部命令（application / program / shell），管理目标文件租约、进程取消、日志与状态栏反馈。
@MainActor
final class ExternalCommandRunner {
    typealias ApplicationOpener = @MainActor (_ urls: [URL], _ applicationURL: URL) async throws -> Void

    private static let stderrTailLineLimit = 20

    private let processRunner = ProcessRunner()
    var applicationOpener: ApplicationOpener = ExternalCommandRunner.defaultApplicationOpener

    static func defaultApplicationOpener(urls: [URL], applicationURL: URL) async throws {
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: .init())
    }

    func run(
        _ command: ExternalCommand,
        target: ScriptTarget,
        services: CoreServices,
        app: AppDelegate?
    ) async -> ExternalRunResult {
        let statusWindow = target.window ?? app?.mainController ?? app?.activeReaderController
        let log = services.scriptLog

        let leases: [FileLease]
        do {
            // 先经数据源确认目标仍可达：网络卷断开或文件被移走时，有些命令（如 sips）对缺失文件仍返回 0，不能指望命令自己报错。
            for location in target.locations {
                try Task.checkCancellation()
                _ = try await services.sources.provider(for: location).entry(at: location)
            }
            leases = try await FileOperationController.resolveLeases(for: target.locations, in: services)
        } catch is CancellationError {
            return .failed(String(localized: "已取消"))
        } catch {
            return reportFailure(command: command, reason: ErrorText.describe(error), stderr: nil, statusWindow: statusWindow, log: log)
        }

        if Task.isCancelled {
            return .failed(String(localized: "已取消"))
        }

        switch command.kind {
        case .application:
            return await runApplication(command, leases: leases, statusWindow: statusWindow, log: log, app: app)
        case .program:
            return await runProgram(command, leases: leases, statusWindow: statusWindow, log: log)
        case .shell:
            return await runShell(command, leases: leases, statusWindow: statusWindow, log: log)
        }
    }

    // MARK: - 三类外部命令执行

    private func runApplication(
        _ command: ExternalCommand,
        leases: [FileLease],
        statusWindow: ReaderWindowController?,
        log: ScriptLog?,
        app: AppDelegate?
    ) async -> ExternalRunResult {
        let rawProgram = (command.program ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawProgram.isEmpty else {
            return reportFailure(command: command, reason: String(localized: "未指定应用程序路径"), stderr: nil, statusWindow: statusWindow, log: log)
        }
        let appURL = URL(fileURLWithPath: (rawProgram as NSString).expandingTildeInPath)

        // 应用类交出文件后无法得知对方何时读取完毕，沿用 FileOperationController.openWithLeases 保留到 App 退出。
        app?.fileOps?.retainOpenWithLeases(leases)

        do {
            try await applicationOpener(leases.map(\.url), appURL)
            return .succeeded(output: nil)
        } catch is CancellationError {
            return .failed(String(localized: "已取消"))
        } catch {
            return reportFailure(command: command, reason: ErrorText.describe(error), stderr: nil, statusWindow: statusWindow, log: log)
        }
    }

    private func runProgram(
        _ command: ExternalCommand,
        leases: [FileLease],
        statusWindow: ReaderWindowController?,
        log: ScriptLog?
    ) async -> ExternalRunResult {
        let rawProgram = (command.program ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawProgram.isEmpty else {
            return reportFailure(command: command, reason: String(localized: "未指定程序路径"), stderr: nil, statusWindow: statusWindow, log: log)
        }
        let executable = (rawProgram as NSString).expandingTildeInPath
        let filePaths = leases.map { $0.url.path(percentEncoded: false) }
        let values = templateValues(files: filePaths, window: statusWindow)
        let workingDirectory = Self.resolvedWorkingDirectory(command.workingDirectory, firstFile: filePaths.first)

        let arguments: [String]
        do {
            arguments = try CommandTemplate.programArguments(command.arguments, values: values)
        } catch {
            return reportFailure(command: command, reason: ErrorText.describe(error), stderr: nil, statusWindow: statusWindow, log: log)
        }

        defer { _ = leases }
        do {
            let result = try await processRunner.run(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
            return handleProcessResult(result, command: command, statusWindow: statusWindow, log: log)
        } catch is CancellationError {
            return .failed(String(localized: "已取消"))
        } catch {
            return reportFailure(command: command, reason: ErrorText.describe(error), stderr: nil, statusWindow: statusWindow, log: log)
        }
    }

    private func runShell(
        _ command: ExternalCommand,
        leases: [FileLease],
        statusWindow: ReaderWindowController?,
        log: ScriptLog?
    ) async -> ExternalRunResult {
        guard !command.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reportFailure(command: command, reason: String(localized: "未指定 Shell 命令"), stderr: nil, statusWindow: statusWindow, log: log)
        }
        let filePaths = leases.map { $0.url.path(percentEncoded: false) }
        let values = templateValues(files: filePaths, window: statusWindow)
        let workingDirectory = Self.resolvedWorkingDirectory(command.workingDirectory, firstFile: filePaths.first)
        let invocation = CommandTemplate.shellInvocation(command.arguments, values: values)

        defer { _ = leases }
        do {
            let result = try await processRunner.runShell(invocation, workingDirectory: workingDirectory)
            return handleProcessResult(result, command: command, statusWindow: statusWindow, log: log)
        } catch is CancellationError {
            return .failed(String(localized: "已取消"))
        } catch {
            return reportFailure(command: command, reason: ErrorText.describe(error), stderr: nil, statusWindow: statusWindow, log: log)
        }
    }

    // MARK: - 模板值与结果处理

    private func templateValues(files: [String], window: ReaderWindowController?) -> TemplateValues {
        guard let session = window?.session, let book = session.book else {
            return TemplateValues(files: files, book: nil, page: nil)
        }
        return TemplateValues(files: files, book: ScriptLocationCodec.token(for: book.location), page: session.currentPage + 1)
    }

    private func handleProcessResult(
        _ result: ProcessResult,
        command: ExternalCommand,
        statusWindow: ReaderWindowController?,
        log: ScriptLog?
    ) -> ExternalRunResult {
        if result.exitCode == 0 {
            let trimmedOutput = result.stdout.trimmingCharacters(in: .newlines)
            if command.showOutput, !trimmedOutput.isEmpty {
                log?.append(source: command.name, level: .info, text: trimmedOutput)
                let lastLine = Self.lastNonEmptyLine(in: trimmedOutput) ?? trimmedOutput
                statusWindow?.content.statusBar.showMessage(lastLine)
            }
            return .succeeded(output: trimmedOutput.isEmpty ? nil : trimmedOutput)
        }

        let firstStderrLine = Self.firstNonEmptyLine(in: result.stderr)
        let reason = firstStderrLine ?? String(localized: "退出码 \(result.exitCode)")
        return reportFailure(command: command, reason: reason, stderr: result.stderr, statusWindow: statusWindow, log: log)
    }

    private func reportFailure(
        command: ExternalCommand,
        reason: String,
        stderr: String?,
        statusWindow: ReaderWindowController?,
        log: ScriptLog?
    ) -> ExternalRunResult {
        let stderrTail = stderr.map { Self.lastLines($0, limit: Self.stderrTailLineLimit) } ?? ""
        let logText = stderrTail.isEmpty ? reason : stderrTail
        log?.append(source: command.name, level: .error, text: logText)
        statusWindow?.content.statusBar.showMessage(String(localized: "\(command.name) 失败：\(reason)"))
        return .failed(reason)
    }

    private static func resolvedWorkingDirectory(_ configured: String?, firstFile: String?) -> String? {
        if let configured {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (trimmed as NSString).expandingTildeInPath
            }
        }
        guard let firstFile, !firstFile.isEmpty else { return nil }
        return (firstFile as NSString).deletingLastPathComponent
    }

    private static func firstNonEmptyLine(in text: String) -> String? {
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func lastNonEmptyLine(in text: String) -> String? {
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).reversed() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func lastLines(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty, limit > 0 else { return "" }
        let lines = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return lines.suffix(limit).map(String.init).joined(separator: "\n")
    }
}
