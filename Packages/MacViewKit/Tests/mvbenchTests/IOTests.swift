import Darwin
import Foundation
import Testing
@testable import mvbench

struct IOArgumentTests {
    @Test(arguments: [("65536", 65536), ("64K", 64 << 10), ("1m", 1 << 20), ("8M", 8 << 20), ("2G", 2 << 30)])
    func byteCountAcceptsUnits(text: String, bytes: Int) {
        #expect(ByteCount(argument: text)?.bytes == bytes)
    }

    @Test(arguments: ["", "K", "0", "-1M", "1.5M", "1T"])
    func byteCountRejectsInvalidText(text: String) {
        #expect(ByteCount(argument: text) == nil)
    }

    @Test func readCombinesPipelineOptionsOnlyForSMB2() throws {
        let smb2 = try #require(try IOCommand.parseAsRoot(
            ["read", "--label", "t", "--transport", "smb2", "--dir", "/x", "--concurrency", "1", "4", "--depth", "1", "4", "--connections", "1", "4"]
        ) as? ReadCommand)
        #expect(smb2.shapes.map { [$0.concurrency, $0.depth, $0.connections] } == [
            [1, 1, 1], [1, 4, 1], [4, 1, 1], [4, 1, 4], [4, 4, 1], [4, 4, 4],
        ])
        let posix = try #require(try IOCommand.parseAsRoot(["read", "--label", "t", "--dir", "/x", "--concurrency", "1", "4", "--depth", "1", "16"]) as? ReadCommand)
        #expect(posix.shapes == [ReadShape(concurrency: 1, chunk: 1 << 20), ReadShape(concurrency: 4, chunk: 1 << 20)])
    }

    @Test func batchRejectsNestedBatch() throws {
        let file = NSTemporaryDirectory() + "mvbench-batch-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: file) }
        try Data(#"["batch", "/dev/null"]"#.utf8).write(to: URL(fileURLWithPath: file))
        let batch = try BatchCommand.parse([file])
        #expect(throws: ValidationFailure.self) { try batch.run() }
    }

    @Test(arguments: [
        ("/x/[XiuRen秀人网] 2022.06.10 No.5133 某人[85P]", "No.5133"),
        ("/x/[XIUREN秀人网]2022.06.21 VOL.5171 某人", "No.5171"),
        ("/x/[Xiuren秀人网]2022.12.14 NO.5995 某人[88+1P／584MB]", "No.5995"),
        ("/Volumes/Picture/YY/秀人/5001-6000", "5001-6000"),
    ])
    func sampleNamesKeepOnlyAlbumNumbers(path: String, name: String) {
        #expect(SampleDirectory.anonymizedName(path) == name)
    }

    @Test func samplePathsKeepOnlyAlbumNumbers() {
        #expect(SampleDirectory.anonymizedPath("/Volumes/Picture/YY/秀人/5001-6000/[XiuRen秀人网] 2022.06.10 No.5133 某人[85P]")
            == "/Volumes/Picture/YY/秀人/5001-6000/No.5133")
        #expect(SampleDirectory.anonymizedPath("/Volumes/Picture/YY/秀人/5001-6000") == "/Volumes/Picture/YY/秀人/5001-6000")
    }
}

struct MountSourceTests {
    @Test func smbSourceSplitsUserServerAndShare() {
        #expect(SMBShare.parse(source: "//yuwk@192.168.31.201/Picture") == SMBShare(server: "192.168.31.201", share: "Picture", user: "yuwk"))
        #expect(SMBShare.parse(source: "//192.168.31.201/My%20Share") == SMBShare(server: "192.168.31.201", share: "My Share", user: nil))
        #expect(SMBShare.parse(source: "//nas.local") == nil)
        #expect(SMBShare.parse(source: "192.168.31.201:/fs") == nil)
    }

    @Test func nfsSourceSplitsServerAndExport() {
        #expect(NFSExport.parse(source: "192.168.31.201:/fs/1000/nfs") == NFSExport(server: "192.168.31.201", path: "/fs/1000/nfs"))
        #expect(NFSExport.parse(source: "//192.168.31.201/Picture") == nil)
    }

    @Test func relativePathIsMeasuredFromMountPoint() throws {
        let mount = MountInfo(mountPoint: "/Volumes/Picture", fileSystem: "smbfs", source: "//192.168.31.201/Picture")
        #expect(try mount.relativePath(of: "/Volumes/Picture/YY/秀人") == "YY/秀人")
        #expect(try mount.relativePath(of: "/Volumes/Picture") == "")
        #expect(throws: ValidationFailure.self) { try mount.relativePath(of: "/Volumes/PictureX") }
    }
}

struct PosixFilesTests {
    @Test func bothListingMethodsSeeEveryEntry() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        for index in 0..<300 {
            FileManager.default.createFile(atPath: "\(directory)/\(index).jpg", contents: Data([1, 2, 3]))
        }
        try FileManager.default.createDirectory(atPath: "\(directory)/子目录", withIntermediateDirectories: false)
        #expect(try PosixFiles.listWithBulk(directory) == 301)
        #expect(try PosixFiles.listWithReaddir(directory) == 301)
        #expect(throws: SystemCallError.self) { try PosixFiles.listWithBulk(directory + "/不存在") }
    }

    @Test func readWholeAndProbeReadTheFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/a.bin"
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: 300_001))
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 << 10, alignment: 16)
        defer { buffer.deallocate() }
        #expect(try PosixFiles.readWhole(path, into: buffer, noCache: true) == 300_001)
        let timing = try PosixFiles.probe(path, into: buffer, noCache: true)
        #expect(timing.total >= 0)
        #expect(throws: SystemCallError.self) { try PosixFiles.readWhole(directory + "/b.bin", into: buffer, noCache: false) }
    }

    @Test func sampleFilesSkipHiddenEntriesAndDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        for name in ["2.jpg", "1.jpg", ".DS_Store", "._1.jpg"] {
            FileManager.default.createFile(atPath: "\(directory)/\(name)", contents: Data([0]))
        }
        try FileManager.default.createDirectory(atPath: "\(directory)/sub", withIntermediateDirectories: false)
        #expect(try Samples.files(in: directory, limit: nil).map { ($0.path as NSString).lastPathComponent } == ["1.jpg", "2.jpg"])
        #expect(try Samples.files(in: directory, limit: 1).count == 1)
        #expect(try Samples.subdirectories(of: directory).map { ($0 as NSString).lastPathComponent } == ["sub"])
    }

    @Test func networkCountersIncludeLoopback() {
        #expect(NetworkCounters.receivedBytes()["lo0"] != nil)
        #expect(NetworkCounters.delta(from: ["en0": 10], to: ["en0": 10 + (2 << 20), "lo0": 5]) == ["en0": 2 << 20])
        #expect(NetworkCounters.delta(from: ["en0": 0xFFFF_FF00], to: ["en0": 0x20_0000]) == ["en0": 0x20_0100])
    }

    private func temporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "mvbench-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return path
    }
}

struct FaultProxyTests {
    @Test func proxyForwardsPausesAndDrops() throws {
        let server = try EchoServer()
        defer { server.stop() }
        let proxy = try FaultProxy(targets: [.init(host: "127.0.0.1", port: server.port)])
        defer { proxy.stop() }

        let first = try #require(FaultProxy.connect(to: .init(host: "127.0.0.1", port: proxy.ports[0])))
        defer { close(first) }
        try send("a", to: first)
        #expect(receive(from: first, timeout: 2) == "a")

        proxy.set(.pause)
        try send("b", to: first)
        #expect(receive(from: first, timeout: 0.3) == nil)
        proxy.set(.forward)
        #expect(receive(from: first, timeout: 2) == "b")

        proxy.set(.drop)
        #expect(receive(from: first, timeout: 2) == "")
        let refused = try #require(FaultProxy.connect(to: .init(host: "127.0.0.1", port: proxy.ports[0])))
        defer { close(refused) }
        #expect(receive(from: refused, timeout: 2) == "")

        proxy.set(.forward)
        let second = try #require(FaultProxy.connect(to: .init(host: "127.0.0.1", port: proxy.ports[0])))
        defer { close(second) }
        try send("c", to: second)
        #expect(receive(from: second, timeout: 2) == "c")
        #expect(proxy.status.accepted == 2)
    }

    @Test func controlLinesRoundTrip() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { close($0) } }
        ProxyControl.write(Data("pause\nstatus".utf8), to: fds[0])
        shutdown(fds[0], SHUT_WR)
        #expect(ProxyControl.readLine(from: fds[1]) == "pause")
        #expect(ProxyControl.readLine(from: fds[1]) == "status")
        #expect(ProxyControl.readLine(from: fds[1]) == nil)
    }

    private func send(_ text: String, to fd: Int32) throws {
        let written = text.withCString { Darwin.write(fd, $0, strlen($0)) }
        #expect(written == text.utf8.count)
    }

    /// 在 timeout 秒内读到的内容；连接关闭或被重置时为空串，超时为 nil。
    private func receive(from fd: Int32, timeout: Double) -> String? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1_000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(fd, &buffer, buffer.count)
        return count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : ""
    }
}

/// 测试用的回显服务器。
private final class EchoServer: Sendable {
    let port: UInt16
    private let listener: Int32
    private let stopped = AtomicFlag()

    init() throws {
        (listener, port) = try FaultProxy.listen(port: 0)
        Thread { [listener, stopped] in
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            while !stopped.isSet {
                descriptor.revents = 0
                guard poll(&descriptor, 1, 100) > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                Thread {
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while true {
                        let count = Darwin.read(client, &buffer, buffer.count)
                        guard count > 0, Darwin.write(client, buffer, count) == count else { break }
                    }
                    close(client)
                }.start()
            }
            close(listener)
        }.start()
    }

    func stop() {
        stopped.set()
    }
}
