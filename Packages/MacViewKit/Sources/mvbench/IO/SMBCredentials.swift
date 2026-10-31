import Darwin
import Foundation
import Security
import Synchronization

/// SMB 登录凭据。只在内存里使用，不写入日志、结果或参数。
struct SMBCredentials: Sendable, CustomStringConvertible {
    var user: String
    var password: String

    var description: String {
        "SMBCredentials(已隐藏)"
    }

    /// 本进程已取得的凭据。`io batch` 里的多条命令共用，只弹一次钥匙串窗口。
    private static let obtained = Mutex<[String: SMBCredentials]>([:])

    /// 先读登录钥匙串里 Finder 保存的项，系统会弹窗请用户允许；读不到时在终端里提示输入密码。
    static func obtain(server: String, user: String?) throws -> SMBCredentials {
        let key = "\(user ?? "")@\(server)"
        if let cached = obtained.withLock({ $0[key] }) { return cached }
        let credentials = if let user, let found = try keychain(server: server, account: user) {
            found
        } else if let found = try keychain(server: server, account: nil) {
            found
        } else {
            try prompt(server: server, user: user)
        }
        obtained.withLock { $0[key] = credentials }
        return credentials
    }

    private static func keychain(server: String, account: String?) throws -> SMBCredentials? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: server,
            kSecAttrProtocol: kSecAttrProtocolSMB,
            kSecReturnAttributes: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            throw ValidationFailure("读取钥匙串里 \(server) 的 SMB 凭据失败：\(message)")
        }
        guard let attributes = item as? [CFString: Any],
              let account = attributes[kSecAttrAccount] as? String,
              let data = attributes[kSecValueData] as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            throw ValidationFailure("钥匙串里 \(server) 的 SMB 凭据格式不对")
        }
        return SMBCredentials(user: account, password: password)
    }

    private static func prompt(server: String, user: String?) throws -> SMBCredentials {
        guard let user else {
            throw ValidationFailure("钥匙串里没有 \(server) 的 SMB 凭据，挂载来源里也没有用户名")
        }
        var buffer = [CChar](repeating: 0, count: 512)
        defer { _ = memset_s(&buffer, buffer.count, 0, buffer.count) }
        guard readpassphrase("\(server) 的 SMB 密码：", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
            throw ValidationFailure("钥匙串里没有 \(server) 的 SMB 凭据；请在自己的终端里运行，以便输入密码")
        }
        return SMBCredentials(user: user, password: buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }
}
