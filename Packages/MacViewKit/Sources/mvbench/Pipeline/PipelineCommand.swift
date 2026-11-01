import ArgumentParser

struct PipelineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pipeline", abstract: "测量图像管线性能。")
}
