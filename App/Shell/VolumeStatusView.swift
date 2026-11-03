import AppKit
import MVFoundation

extension Location.Root {
    /// 让系统挂载这个卷的地址。
    var mountURL: URL? {
        guard case let .network(scheme, host, share) = self else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + share
        return components.url
    }
}
