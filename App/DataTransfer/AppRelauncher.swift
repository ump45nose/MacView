import AppKit
import Darwin
import Foundation

/// 等当前进程正常退出后，经 LaunchServices 重新启动本 App 的新实例。
@MainActor
enum AppRelauncher {
    /// 启动脱离的 `/bin/sh` 等待本进程 PID 退出后再 `open -n`，随后走正常退出流程。
    static func relaunch(arguments: [String] = Array(ProcessInfo.processInfo.arguments.dropFirst())) throws {
        let script = """
            old_pid=$1
            bundle=$2
            shift 2
            while kill -0 "$old_pid" 2>/dev/null; do /bin/sleep 0.02; done
            if [ "$#" -gt 0 ]; then
                exec /usr/bin/open -n "$bundle" --args "$@"
            else
                exec /usr/bin/open -n "$bundle"
            fi
            """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "relaunch-helper", String(getpid()), Bundle.main.bundleURL.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // 不在主 actor 任务内直接同步调 terminate：嵌套循环会阻塞 shutdown 任务。
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}
