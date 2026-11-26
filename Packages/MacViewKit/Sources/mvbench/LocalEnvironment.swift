import Foundation

/// 本机网络测试配置；不把个人路径作为命令的默认参数（help 中也不会显示）。
struct LocalEnvironment: Decodable {
    var nasHost: String?
    var nfsExport: String?
    var smbRoot: String?
    var sampleDirectory: String?
    var writableTestRoots: [String]?

    static func load() -> Self {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macview/environment.json")
        return load(data: try? Data(contentsOf: path), environment: ProcessInfo.processInfo.environment)
    }

    static func load(data: Data?, environment: [String: String]) -> Self {
        var result = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        func configured(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        result.nasHost = configured(environment["MV_NAS_HOST"] ?? result.nasHost)
        result.nfsExport = configured(environment["MV_NFS_EXPORT"] ?? result.nfsExport)
        result.smbRoot = configured(environment["MV_SMB_ROOT"] ?? result.smbRoot)
        result.sampleDirectory = configured(environment["MV_SAMPLE_DIRECTORY"] ?? result.sampleDirectory)
        return result
    }

    func sampleDirectories(explicit: [String]) throws -> [String] {
        if !explicit.isEmpty { return explicit }
        guard let sampleDirectory else {
            throw ValidationFailure("样本目录未配置：请传 --dir 或设置 MV_SAMPLE_DIRECTORY。")
        }
        return [sampleDirectory]
    }
}
