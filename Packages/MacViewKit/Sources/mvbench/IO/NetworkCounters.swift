import Darwin

/// 各网络接口累计收到的字节数。测量前后各取一次，用来确认数据来自网络、走的是哪个接口。
enum NetworkCounters {
    static func receivedBytes() -> [String: UInt64] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }
        var counters: [String: UInt64] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        counters[name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }] = message.ifm_data.ifi_ibytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return counters
    }

    /// 两次快照之间各接口收到的字节数，只保留超过 1 MiB 的接口。
    /// 无特权进程读到的计数只有低 32 位（macOS 27 实测），差值按 2^32 取模，所以一次测量要少于 4 GiB。
    static func delta(from before: [String: UInt64], to after: [String: UInt64]) -> [String: UInt64] {
        after.reduce(into: [:]) { result, item in
            let received = UInt64(UInt32(truncatingIfNeeded: item.value &- (before[item.key] ?? item.value)))
            if received > 1 << 20 { result[item.key] = received }
        }
    }
}
