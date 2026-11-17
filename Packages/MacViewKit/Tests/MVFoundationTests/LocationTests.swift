import Foundation
import Testing
@testable import MVFoundation

private let nas = Location.Root.network(scheme: "nfs", host: "nas.local", share: "/export")

struct LocationTests {
    @Test func c11PlaylistAndPrefixKeys() {
        let id = UUID()
        #expect(Location.playlistRootID == "playlist")
        #expect(Location.playlist(id).playlistID == id)
        #expect(Location(root: .plugin(id: "playlist"), layers: [[id.uuidString, "extra"]]).playlistID == nil)
        #expect(Location(root: .local, layers: [[id.uuidString]]).playlistID == nil)
        let emptyRoot = Location(root: .local, layers: [])
        #expect(emptyRoot.hasPrefix(emptyRoot))
        #expect(emptyRoot.hasPrefix(Location(root: .local)))
        #expect(emptyRoot.prefixKey == Location(root: .local).prefixKey)
        var seed: UInt64 = 0xC11
        func random(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(count))
        }
        let roots: [Location.Root] = [.local, nas, .plugin(id: "a:/!"), .network(scheme: "smb", host: "主机", share: "/a!")]
        let names = ["a", "a/b", "!", "/", "汉字", "a\u{1f}b", "", "é", "e\u{301}", "%:0"]
        for _ in 0..<1000 {
            let root = roots[random(roots.count)]
            let layers = (0..<(1 + random(3))).map { _ in (0..<(1 + random(3))).map { _ in names[random(names.count)] } }
            let location = Location(root: root, layers: layers)
            let layer = random(layers.count)
            var prefixLayers = Array(layers.prefix(layer + 1))
            prefixLayers[layer] = Array(prefixLayers[layer].prefix(random(prefixLayers[layer].count + 1)))
            let prefix = Location(root: root, layers: prefixLayers)
            for candidate in [prefix, Location(root: roots[random(roots.count)], layers: [[names[random(names.count)]]]), Location(root: root)] {
                let keyMatches = location.prefixKey == candidate.prefixKey || location.prefixKey.hasPrefix(candidate.prefixKey + "/")
                #expect(location.hasPrefix(candidate) == keyMatches)
            }
        }
    }

    @Test(arguments: [
        Location(root: .local, layers: [["Users", "me", "a.jpg"]]),
        Location(root: nas, layers: [["Picture", "a.zip"], ["inner", "b.zip"], ["001.jpg"]]),
        Location(root: .plugin(id: "web"), layers: [["feed"]]),
        Location(root: nas),
    ])
    func jsonRoundTrip(location: Location) throws {
        #expect(try JSONDecoder().decode(Location.self, from: JSONEncoder().encode(location)) == location)
    }

    /// 书记忆和历史按这个结构持久化。
    @Test func jsonKeepsRootAndLayers() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(Location(root: nas, layers: [["a.zip"], ["001.jpg"]])), as: UTF8.self)
        #expect(json == #"{"layers":[["a.zip"],["001.jpg"]],"root":{"network":{"host":"nas.local","scheme":"nfs","share":"/export"}}}"#)
    }

    @Test func navigatesAcrossArchiveLayers() {
        let root = Location(root: nas)
        let archive = root.appending("Picture").appending("a.zip")
        let inner = archive.appendingLayer(["inner"])
        let page = inner.appending("b.zip").appendingLayer(["001.jpg"])
        #expect(page.layers == [["Picture", "a.zip"], ["inner", "b.zip"], ["001.jpg"]])
        #expect(page.description == "/export/Picture/a.zip!/inner/b.zip!/001.jpg")
        #expect(page.name == "001.jpg")
        #expect(page.parent == inner.appending("b.zip"))
        #expect(inner.parent == archive)
        #expect(archive.parent?.parent == root)
        #expect(root.parent == nil)
        #expect(root.name.isEmpty)
    }

    @Test func prefixMatchesWholeComponentsAndArchiveContents() {
        let base = Location(root: nas, layers: [["Picture", "YY"]])
        #expect(base.hasPrefix(base))
        #expect(Location(root: nas, layers: [["Picture", "YY", "a.zip"], ["001.jpg"]]).hasPrefix(base))
        #expect(!Location(root: nas, layers: [["Picture", "YYZ"]]).hasPrefix(base))
        #expect(!Location(root: nas, layers: [["Picture"]]).hasPrefix(base))
        #expect(!Location(root: .local, layers: [["Picture", "YY"]]).hasPrefix(base))
        let archive = Location(root: nas, layers: [["a.zip"]])
        #expect(archive.appendingLayer(["x.jpg"]).hasPrefix(archive))
    }
}

struct ContentIdentityTests {
    private let identity = ContentIdentity(
        location: Location(root: nas, layers: [["Picture", "a.zip"], ["001.jpg"]]),
        size: 123_456, modificationNanos: 1_700_000_000_123_456_789, checksum: 0xDEAD_BEEF
    )

    /// 期望值由独立的脚本按同样的编码算出。它变了，已有的磁盘缓存就全部失效。
    @Test func cacheKeyIsStable() {
        #expect(identity.cacheKey == "d878e629b19b53f62d03c70701f5e41b")
    }

    @Test func cacheKeyChangesWithEveryField() throws {
        var variants = Array(repeating: identity, count: 6)
        variants[0].size += 1
        variants[1].modificationNanos += 1
        variants[2].checksum = nil
        variants[3].location = try #require(identity.location.parent)
        variants[4].location.root = .local
        variants[5].location.layers = [["Picture", "a.zip", "001.jpg"]]
        #expect(Set(variants.map(\.cacheKey) + [identity.cacheKey]).count == variants.count + 1)
    }
}

@Test func jsonValueDecodesPlainJSON() throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":[1,true,null,"x",{"b":2.5}],"c":false}"#.utf8))
    #expect(value == .object(["a": .array([.number(1), .bool(true), .null, .string("x"), .object(["b": .number(2.5)])]), "c": .bool(false)]))
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
}

@Test func entryReadsLocationSizeAndDateFromIdentity() {
    let identity = ContentIdentity(location: Location(root: .local, layers: [["a.jpg"]]), size: 10, modificationNanos: 1_500_000_000)
    let entry = Entry(identity: identity, name: "a.jpg", kind: .image)
    #expect(entry.location == identity.location)
    #expect(entry.size == 10)
    #expect(entry.modified == Date(timeIntervalSince1970: 1.5))
}
