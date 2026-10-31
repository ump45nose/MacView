import ArgumentParser
import Darwin
import Foundation
import Synchronization

extension FaultProxy.Mode: ExpressibleByArgument {}

/// `mvbench io fault`：通过 proxy 的控制端口让测试挂载卡住或断线，记录调用的阻塞、错误与恢复，
/// 以及 I/O 线程被卡住时进程能否按时退出。
struct FaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fault",
        abstract: "让测试挂载卡住或断线，记录调用阻塞、错误、恢复，以及卡住时进程能否按时退出。",
        discussion: """
            每个场景：两个线程分别循环做小读（F_NOCACHE）和列目录；3 秒后施加故障，持续 --duration 秒后恢复，
            等两种操作在恢复后各成功 3 次（最多 --recovery-timeout 秒）。
            退出测试：子进程 `mvbench io hold` 的 I/O 线程反复小读，施加故障 --exit-delay 秒后让它的主线程调用 exit(0)，
            记录多久后进程真正消失；超过 --exit-timeout 秒发 SIGKILL。另测一次无故障时的退出作为对照。
            """
    )

    @OptionGroup var report: ReportOptions

    @Option(help: "proxy 打印的控制端口。")
    var control: UInt16

    @Option(name: .customLong("dir"), help: "测试挂载下含有若干图集目录的目录。")
    var directory: String

    @Option(parsing: .upToNextOption, help: "故障方式：pause（暂停转发）、drop（切断连接）。")
    var mode: [FaultProxy.Mode] = [.pause, .drop]

    @Option(parsing: .upToNextOption, help: "故障持续的秒数，可给多个值。")
    var duration: [Double] = [5, 15, 30, 60]

    @Option(help: "故障结束后最多等待恢复的秒数。")
    var recoveryTimeout: Double = 90

    @Option(help: "退出测试中等待子进程退出的秒数，超过后发 SIGKILL。")
    var exitTimeout: Double = 30

    @Option(parsing: .upToNextOption, help: "退出测试中施加故障到请求退出的秒数，可给多个值。")
    var exitDelay: [Double] = [2]

    @Flag(help: "跳过退出测试。")
    var skipExitTest = false

    @Flag(help: "只做退出测试。")
    var exitTestOnly = false

    func run() throws {
        let albums = try Samples.subdirectories(of: directory)
        // 小读用前两个直接含有文件的子目录；有的子目录里只套着一层目录。
        var files: [String] = []
        var albumsWithFiles = 0
        for album in albums where albumsWithFiles < 2 {
            let found = try Samples.files(in: album, limit: nil)
            if found.isEmpty { continue }
            files += found.map(\.path)
            albumsWithFiles += 1
        }
        guard !files.isEmpty else { throw ValidationFailure("\(directory) 下没有可读的图集") }
        try ProxyControl.send("forward", port: control)

        var scenarios: [FaultScenario] = []
        scenarioLoop: for mode in exitTestOnly ? [] : mode {
            for seconds in duration {
                let scenario = try runScenario(mode: mode, seconds: seconds, files: files, directories: albums)
                scenarios.append(scenario)
                progress("\(report.label) \(mode.rawValue) \(Int(seconds)) 秒：挂载\(scenario.mountedAfter ? "仍在" : "已消失")，未返回 \(scenario.stuck)")
                if !scenario.stuck.isEmpty || !scenario.mountedAfter { break scenarioLoop }
            }
        }

        var exitTests: [ExitTest] = []
        // 挂载已经消失时子进程读不到文件，退出测试没有意义。
        if !skipExitTest, scenarios.last?.mountedAfter ?? true {
            let cases = [(FaultProxy.Mode.forward, exitDelay[0])] + mode.flatMap { mode in exitDelay.map { (mode, $0) } }
            for (mode, delay) in cases {
                var test: ExitTest
                do {
                    test = try runExitTest(mode: mode, delay: delay, files: Array(files.prefix(20)))
                } catch {
                    _ = try? ProxyControl.send("forward", port: control)
                    test = ExitTest(mode: mode, delaySeconds: delay, error: "\(error)")
                }
                exitTests.append(test)
                let outcome = test.error ?? test.exitMilliseconds.map { "exit \(Int($0)) ms" } ?? "exit 超时"
                progress("\(report.label) 退出测试 \(mode.rawValue) \(Int(delay)) 秒：\(outcome)")
            }
        }

        let result = FaultResult(
            proxy: try ProxyControl.send("status", port: control),
            scenarios: scenarios,
            exitTests: exitTests
        )
        try IOReport.write(result, label: report.label, transport: .posix, paths: [directory], output: report.output)
    }

    private func runScenario(mode: FaultProxy.Mode, seconds: Double, files: [String], directories: [String]) throws -> FaultScenario {
        let log = OperationLog()
        let stop = AtomicFlag()
        let clock = ContinuousClock()
        let origin = clock.now
        let loops = DispatchGroup()
        for kind in FaultOperation.Kind.allCases {
            loops.enter()
            Thread {
                defer { loops.leave() }
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 << 10, alignment: Int(getpagesize()))
                defer { buffer.deallocate() }
                var index = 0
                while !stop.isSet {
                    let begin = clock.now
                    log.begin(kind)
                    var failure: String?
                    do {
                        switch kind {
                        case .probe: _ = try PosixFiles.probe(files[index % files.count], into: buffer, noCache: true)
                        case .list: _ = try PosixFiles.listWithBulk(directories[index % directories.count])
                        }
                    } catch {
                        failure = "\(error)"
                    }
                    log.append(FaultOperation(kind: kind, start: (begin - origin).seconds, milliseconds: (clock.now - begin).milliseconds, error: failure))
                    index += 1
                    usleep(50_000)
                }
            }.start()
        }

        Thread.sleep(forTimeInterval: 3)
        let faultStart = (clock.now - origin).seconds
        try ProxyControl.send(mode.rawValue, port: control)
        Thread.sleep(forTimeInterval: seconds)
        try ProxyControl.send("forward", port: control)
        let faultEnd = (clock.now - origin).seconds

        let deadline = clock.now + .seconds(recoveryTimeout)
        while clock.now < deadline, !log.recovered(after: faultEnd, successes: 3) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        stop.set()
        let returned = loops.wait(timeout: .now() + abandonAfterSeconds) == .success
        let operations = log.operations
        let stuck = returned ? [] : log.inFlight.map(\.rawValue).sorted()
        let directory = directory
        let mount = BlockingCall.start { try? MountInfo.of(directory) }.wait(seconds: 5) ?? nil
        let mounted = mount.map { $0.fileSystem == "smbfs" || $0.fileSystem == "nfs" } ?? false
        return FaultScenario(
            mode: mode,
            durationSeconds: seconds,
            faultStart: faultStart,
            faultEnd: faultEnd,
            loops: FaultOperation.Kind.allCases.map { kind in
                FaultLoopSummary(kind: kind, operations: operations.filter { $0.kind == kind }, faultStart: faultStart, faultEnd: faultEnd)
            },
            mountedAfter: mounted,
            stuck: stuck,
            notable: operations.filter { $0.error != nil || $0.milliseconds > 500 }.prefix(200).map { $0 }
        )
    }

    private func runExitTest(mode: FaultProxy.Mode, delay: Double, files: [String]) throws -> ExitTest {
        guard let executable = Bundle.main.executablePath else { throw ValidationFailure("找不到 mvbench 的可执行文件路径") }
        let child = try ChildProcess(executable, ["io", "hold", "--threads", "2"] + files.flatMap { ["--file", $0] })
        guard child.readLine(timeout: 30) == "ready" else {
            child.kill()
            throw ValidationFailure("hold 子进程 30 秒内没有完成第一次读取")
        }
        if mode != .forward { try ProxyControl.send(mode.rawValue, port: control) }
        Thread.sleep(forTimeInterval: delay)
        let clock = ContinuousClock()
        var test = ExitTest(mode: mode, delaySeconds: delay)
        let asked = clock.now
        child.send("exit")
        if child.waitForExit(timeout: exitTimeout) {
            test.exitMilliseconds = (clock.now - asked).milliseconds
        } else {
            let killed = clock.now
            child.kill()
            if child.waitForExit(timeout: exitTimeout) { test.killMilliseconds = (clock.now - killed).milliseconds }
        }
        let resumed = clock.now
        try ProxyControl.send("forward", port: control)
        if test.exitMilliseconds == nil, test.killMilliseconds == nil, child.waitForExit(timeout: abandonAfterSeconds) {
            test.exitAfterResumeMilliseconds = (clock.now - resumed).milliseconds
        }
        return test
    }
}

struct FaultResult: Encodable {
    var proxy: FaultProxy.Status
    var scenarios: [FaultScenario]
    var exitTests: [ExitTest]
}

/// 故障测试里的一次操作。start 为相对场景开始的秒数，耗时单位为毫秒。
struct FaultOperation: Codable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// 打开、读开头 64 KB、关闭，F_NOCACHE。
        case probe
        /// getattrlistbulk 列一个图集目录。
        case list
    }

    var kind: Kind
    var start: Double
    var milliseconds: Double
    var error: String?

    var end: Double {
        start + milliseconds / 1_000
    }
}

struct FaultScenario: Codable {
    var mode: FaultProxy.Mode
    var durationSeconds: Double
    var faultStart: Double
    var faultEnd: Double
    var loops: [FaultLoopSummary]
    /// 场景结束后测试挂载是否还在。
    var mountedAfter: Bool
    /// 放弃等待时仍未返回的操作种类。
    var stuck: [String]
    /// 出错或耗时超过 500 ms 的操作，最多 200 条。
    var notable: [FaultOperation]
}

/// 一种操作在一个场景里的表现。时间单位：秒；耗时：毫秒。
struct FaultLoopSummary: Codable {
    var kind: FaultOperation.Kind
    var operations: Int
    /// 故障开始前完成的操作的耗时。
    var baseline: Summary?
    /// 与故障时段重叠的操作中最长的耗时。
    var longestBlockMilliseconds: Double?
    /// 与故障时段重叠的操作返回的错误。
    var errorsDuringFault: [String: Int]
    /// 故障开始到第一次返回错误的秒数。
    var firstErrorAfterStart: Double?
    /// 故障结束后才开始的操作返回的错误。
    var errorsAfterFault: [String: Int]
    /// 故障结束到第一个成功操作完成的秒数，该操作必须在故障结束后开始。
    var recoveryAfterEnd: Double?

    init(kind: FaultOperation.Kind, operations: [FaultOperation], faultStart: Double, faultEnd: Double) {
        self.kind = kind
        self.operations = operations.count
        baseline = Summary(operations.filter { $0.end < faultStart && $0.error == nil }.map(\.milliseconds))
        let overlapping = operations.filter { $0.start < faultEnd && $0.end > faultStart }
        longestBlockMilliseconds = overlapping.map(\.milliseconds).max()
        errorsDuringFault = errorCounts(overlapping.map(\.error))
        firstErrorAfterStart = operations.filter { $0.error != nil && $0.end >= faultStart }.map { $0.end - faultStart }.min()
        let after = operations.filter { $0.start >= faultEnd }
        errorsAfterFault = errorCounts(after.map(\.error))
        recoveryAfterEnd = after.filter { $0.error == nil }.map { $0.end - faultEnd }.min()
    }
}

/// 一次退出测试。耗时单位为毫秒。
struct ExitTest: Codable {
    /// forward 表示无故障时的对照。
    var mode: FaultProxy.Mode
    /// 施加故障到请求退出的秒数。
    var delaySeconds: Double
    /// 主线程调用 exit(0) 到进程消失。
    var exitMilliseconds: Double?
    /// exit 超时后发 SIGKILL 到进程消失。
    var killMilliseconds: Double?
    /// 两者都超时时，故障结束到进程消失。
    var exitAfterResumeMilliseconds: Double?
    /// 没能完成这次测试的原因，例如子进程读不到文件。
    var error: String?
}

/// 多个线程追加的操作记录。
final class OperationLog: Sendable {
    private let storage = Mutex<(operations: [FaultOperation], inFlight: Set<FaultOperation.Kind>)>(([], []))

    /// 记录某种操作开始；append 时清除。用来找出放弃等待时仍未返回的操作。
    func begin(_ kind: FaultOperation.Kind) {
        storage.withLock { _ = $0.inFlight.insert(kind) }
    }

    func append(_ operation: FaultOperation) {
        storage.withLock {
            $0.operations.append(operation)
            $0.inFlight.remove(operation.kind)
        }
    }

    var inFlight: Set<FaultOperation.Kind> {
        storage.withLock { $0.inFlight }
    }

    var operations: [FaultOperation] {
        storage.withLock { $0.operations }
    }

    /// 每种操作在 time 之后开始并成功的次数都达到 successes。
    func recovered(after time: Double, successes: Int) -> Bool {
        let operations = operations
        return FaultOperation.Kind.allCases.allSatisfy { kind in
            operations.filter { $0.kind == kind && $0.start >= time && $0.error == nil }.count >= successes
        }
    }
}

final class AtomicFlag: Sendable {
    private let value = Atomic<Bool>(false)

    var isSet: Bool {
        value.load(ordering: .relaxed)
    }

    func set() {
        value.store(true, ordering: .relaxed)
    }

    /// 第一次设置时返回 true。
    func setFirst() -> Bool {
        !value.exchange(true, ordering: .relaxed)
    }
}

/// 用 posix_spawn 启动的子进程，自己用 waitpid 回收，以便精确记录退出的时刻。
final class ChildProcess {
    let pid: pid_t
    private let input: Int32
    private let output: Int32

    init(_ executable: String, _ arguments: [String]) throws {
        var inputPipe: [Int32] = [0, 0]
        var outputPipe: [Int32] = [0, 0]
        guard pipe(&inputPipe) == 0, pipe(&outputPipe) == 0 else { throw SystemCallError.last("pipe") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, inputPipe[1])
        posix_spawn_file_actions_addclose(&actions, outputPipe[0])
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + environment).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, nil, argv, environment)
        close(inputPipe[0])
        close(outputPipe[1])
        guard status == 0 else {
            close(inputPipe[1])
            close(outputPipe[0])
            throw SystemCallError(call: "posix_spawn", code: status)
        }
        self.pid = pid
        input = inputPipe[1]
        output = outputPipe[0]
    }

    deinit {
        close(input)
        close(output)
    }

    func send(_ line: String) {
        ProxyControl.write(Data((line + "\n").utf8), to: input)
    }

    /// 等 timeout 秒读一行输出。
    func readLine(timeout: Double) -> String? {
        var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1_000)) > 0 else { return nil }
        return ProxyControl.readLine(from: output)
    }

    /// 每 5 ms 检查一次子进程是否已退出。
    func waitForExit(timeout: Double) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(Int(timeout * 1_000))
        var status: Int32 = 0
        while clock.now < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { return true }
            usleep(5_000)
        }
        return false
    }

    func kill() {
        Darwin.kill(pid, SIGKILL)
    }
}

/// `mvbench io hold`：退出测试用的子进程。I/O 线程反复小读，主线程收到 exit 后调用 exit(0)。
struct HoldCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hold",
        abstract: "退出测试用的子进程：I/O 线程反复小读，主线程收到 exit 后调用 exit(0)。",
        shouldDisplay: false
    )

    @Option(name: .customLong("file"), help: "反复小读的文件，可重复。")
    var files: [String]

    @Option(help: "I/O 线程数。")
    var threads = 2

    func run() throws {
        let files = files
        let announced = AtomicFlag()
        for index in 0..<threads {
            Thread {
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 << 10, alignment: Int(getpagesize()))
                var next = index
                while true {
                    if (try? PosixFiles.probe(files[next % files.count], into: buffer, noCache: true)) != nil, announced.setFirst() {
                        FileHandle.standardOutput.write(Data("ready\n".utf8))
                    }
                    next += 1
                }
            }.start()
        }
        while let line = Swift.readLine() {
            if line == "exit" { Darwin.exit(0) }
        }
        Darwin.exit(0)
    }
}

extension Duration {
    var seconds: Double {
        milliseconds / 1_000
    }
}
