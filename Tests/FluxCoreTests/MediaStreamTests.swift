import Foundation
import Testing
@testable import FluxCore

private func mediaLine(_ payload: [String: Any], diff: Bool) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["type": "data", "diff": diff, "payload": payload])
    data.append(10)
    return data
}

@Test func mediaMergesFragmentedDiffsAndClearsOnlyExplicitNulls() throws {
    var stream = MediaStream()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let line = try mediaLine(["bundleIdentifier": "org.fluxfixture.player", "title": "Example track", "artist": "Example artist",
                              "playing": true, "duration": 100, "elapsedTime": 20, "playbackRate": 2,
                              "timestamp": "2027-01-15T08:00:00Z", "artworkData": Data([1, 2, 3]).base64EncodedString()], diff: false)
    #expect(try stream.append(line.prefix(10), now: date).isEmpty)
    let first = try #require(stream.append(line.dropFirst(10), now: date).first.flatMap { $0 })
    #expect(first.title == "Example track")
    #expect(first.artwork == Data([1, 2, 3]))
    let changed = try #require(stream.append(mediaLine(["elapsedTime": 30, "artist": NSNull()], diff: true), now: date).first.flatMap { $0 })
    #expect(changed.title == first.title)
    #expect(changed.artist.isEmpty)
    #expect(changed.artworkID == first.artworkID)
    #expect(changed.elapsed(at: changed.sampledAt.addingTimeInterval(10)) == 50)
    let paused = try #require(stream.append(mediaLine(["playing": false, "artworkData": NSNull()], diff: true), now: date).first.flatMap { $0 })
    #expect(paused.artwork == nil)
    #expect(paused.elapsed(at: date.addingTimeInterval(1000)) == changed.elapsed(at: date))
    let empty = try stream.append(mediaLine([:], diff: false), now: date)
    #expect(empty.count == 1)
    #expect(empty[0] == nil)
}

@Test func mediaPlayingOnlyDiffFreezesAndResumesTheClockWithoutCountingPausedTime() throws {
    var stream = MediaStream()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try stream.append(mediaLine(["title": "Fixture", "playing": true, "elapsedTime": 20,
                                    "duration": 100], diff: false), now: date)
    let paused = try #require(stream.append(mediaLine(["playing": false], diff: true),
                                           now: date.addingTimeInterval(10)).first.flatMap { $0 })
    #expect(paused.elapsed(at: date.addingTimeInterval(50)) == 30)
    let resumed = try #require(stream.append(mediaLine(["playing": true], diff: true),
                                            now: date.addingTimeInterval(50)).first.flatMap { $0 })
    #expect(resumed.elapsed(at: date.addingTimeInterval(55)) == 35)
    let seek = try #require(stream.append(mediaLine(["elapsedTime": 5, "timestamp": NSNull()], diff: true),
                                         now: date.addingTimeInterval(60)).first.flatMap { $0 })
    #expect(seek.elapsed(at: date.addingTimeInterval(61)) == 6)
}

@Test func mediaCapsMalformedFramesAndPlaybackNumbers() throws {
    var stream = MediaStream()
    #expect(throws: MediaWireError.self) { try stream.append(Data(repeating: 1, count: 65537)) }
    #expect(throws: (any Error).self) { try stream.append(Data("not-json\n".utf8)) }
    let state = try #require(stream.append(mediaLine(["title": "Example", "duration": 1e200, "elapsedTime": -20,
                                                      "playing": true, "playbackRate": 1e100], diff: false)).first.flatMap { $0 })
    #expect(state.duration == nil)
    #expect(state.elapsed == nil)
    #expect(state.rate == 4)
}
