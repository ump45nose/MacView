import Foundation
import Testing
@testable import mvbench

@Test(arguments: [
    ("//yuwk@192.168.31.201/Picture", "//192.168.31.201/Picture"),
    ("//GUEST:@nas.local/Media", "//nas.local/Media"),
    ("//192.168.31.201/Picture", "//192.168.31.201/Picture"),
    ("192.168.31.201:/fs/1000/nfs", "192.168.31.201:/fs/1000/nfs"),
    ("/dev/disk3s1s1", "/dev/disk3s1s1"),
])
func mountSourceDropsUserName(source: String, expected: String) {
    #expect(BenchEnvironment.redactingUser(source) == expected)
}

@Test func collectsLocalVolume() {
    let environment = BenchEnvironment.collect(paths: [NSTemporaryDirectory(), "/no/such/path"], host: nil)
    #expect(!environment.system.version.isEmpty)
    #expect(environment.machine.memoryBytes ?? 0 > 0)
    let local = environment.volumes[0]
    #expect(local.error == nil)
    #expect(local.fileSystem == "apfs")
    #expect(environment.volumes[1].error != nil)
}
