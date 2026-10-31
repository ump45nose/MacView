import Foundation
import Testing
@testable import mvbench

@Test(arguments: [
    ("//yuwk@nas.example/Picture", "//nas.example/Picture"),
    ("//GUEST:@nas.local/Media", "//nas.local/Media"),
    ("//nas.example/Picture", "//nas.example/Picture"),
    ("nas.example:/export", "nas.example:/export"),
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
