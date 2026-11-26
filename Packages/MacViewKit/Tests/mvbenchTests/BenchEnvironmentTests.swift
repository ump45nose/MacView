import Foundation
import Testing
@testable import mvbench

@Test(arguments: [
    ("//user@nas.example/Photos", "//nas.example/Photos"),
    ("//GUEST:@nas.example/Media", "//nas.example/Media"),
    ("//nas.example/Photos", "//nas.example/Photos"),
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

@Test func localEnvironmentUsesPerFieldOverrides() {
    let file = Data(#"{"nasHost":"nas.example","nfsExport":"/export/Photos","smbRoot":"/Volumes/Photos","sampleDirectory":"/Volumes/Photos/Samples/Set-A","writableTestRoots":[]}"#.utf8)
    let configuration = LocalEnvironment.load(data: file, environment: ["MV_NAS_HOST": "localhost", "MV_SAMPLE_DIRECTORY": "/Volumes/Mock"])
    #expect(configuration.nasHost == "localhost")
    #expect(configuration.nfsExport == "/export/Photos")
    #expect(configuration.smbRoot == "/Volumes/Photos")
    #expect(configuration.sampleDirectory == "/Volumes/Mock")
    #expect(configuration.writableTestRoots == [])
    #expect(LocalEnvironment.load(data: nil, environment: [:]).sampleDirectory == nil)
}

@Test func explicitSampleDirectoriesTakePriority() throws {
    let configuration = LocalEnvironment.load(data: nil, environment: ["MV_SAMPLE_DIRECTORY": "/Volumes/Mock/Samples"])
    #expect(try configuration.sampleDirectories(explicit: ["/tmp/example"]) == ["/tmp/example"])
    #expect(try configuration.sampleDirectories(explicit: []) == ["/Volumes/Mock/Samples"])
    #expect(throws: ValidationFailure.self) {
        try LocalEnvironment.load(data: nil, environment: [:]).sampleDirectories(explicit: [])
    }
}
