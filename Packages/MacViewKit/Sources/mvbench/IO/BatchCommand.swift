import ArgumentParser
import Foundation

/// `mvbench io batch`：在同一个进程里依次运行多条 io 子命令，smb2 只需取一次凭据。
struct BatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "在同一个进程里依次运行文件里的 io 子命令；smb2 的凭据只取一次。",
        discussion: """
            命令文件每行一条，写成 JSON 字符串数组，例如 ["read", "--transport", "smb2", "--dir", "/Volumes/x"]。任一条失败即停止。
            ["wait", 路径] 等到该文件出现再继续，用来先取得凭据、等网络空闲后再测量。
            """
    )

    @Argument(help: "命令文件的路径。")
    var file: String

    func run() throws {
        let lines = try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n")
        for (index, line) in lines.enumerated() {
            let arguments = try JSONDecoder().decode([String].self, from: Data(line.utf8))
            if arguments.count == 2, arguments[0] == "wait" {
                progress("等待 \(arguments[1]) 出现")
                while !FileManager.default.fileExists(atPath: arguments[1]) { Thread.sleep(forTimeInterval: 1) }
                continue
            }
            guard arguments.first != "batch" else { throw ValidationFailure("第 \(index + 1) 行：batch 不能嵌套") }
            var command = try IOCommand.parseAsRoot(arguments)
            try command.run()
        }
    }
}
