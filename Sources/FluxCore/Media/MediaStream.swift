import CoreFoundation
import CryptoKit
import Foundation

public struct MediaSnapshot: Equatable, Sendable {
    public let source: ApplicationID?
    public let title: String
    public let artist: String
    public let album: String
    public let playing: Bool
    public let duration: TimeInterval?
    public let elapsed: TimeInterval?
    public let sampledAt: Date
    public let rate: Double
    public let canSkip: Bool
    public let artwork: Data?
    public let artworkID: UUID?

    public func elapsed(at date: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        let delta = playing ? max(0, date.timeIntervalSince(sampledAt)) * rate : 0
        return min(max(0, elapsed + delta), duration ?? .greatestFiniteMagnitude)
    }
}

public enum MediaWireError: Error { case tooLarge, malformed }

/// The pinned BSD adapter emits full/diff JSON lines. This value parser
/// retains fixed metadata fields and one bounded artwork, never a log of tracks.
public struct MediaStream: Sendable {
    public static let maximumLineBytes = 8 * 1024 * 1024
    private enum Scalar: Sendable { case text(String), number(Double), flag(Bool) }
    private var buffer = Data()
    private var fields: [String: Scalar] = [:]
    private var artwork: Data?
    private var artworkID: UUID?
    private var artworkHash: SHA256.Digest?
    private var lastSnapshot: MediaSnapshot?
    private var anchorElapsed: TimeInterval?
    private var anchorTimestamp: Date?
    private static let textKeys: Set<String> = ["bundleIdentifier", "title", "artist", "album", "timestamp"]
    private static let numberKeys: Set<String> = ["duration", "elapsedTime", "playbackRate"]
    private static let flagKeys: Set<String> = ["playing", "prohibitsSkip"]

    public init() {}

    public mutating func append(_ data: Data, now: Date = .now) throws -> [MediaSnapshot?] {
        guard data.count <= 64 * 1024, buffer.count + data.count <= Self.maximumLineBytes else { throw MediaWireError.tooLarge }
        buffer.append(data)
        var results: [MediaSnapshot?] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { results.append(try consume(line, now: now)) }
        }
        return results
    }

    private mutating func consume(_ line: Data, now: Date) throws -> MediaSnapshot? {
        guard let envelope = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              envelope["type"] as? String == "data",
              let diff = envelope["diff"] as? NSNumber, CFGetTypeID(diff) == CFBooleanGetTypeID(),
              let payload = envelope["payload"] as? [String: Any] else { throw MediaWireError.malformed }
        if !diff.boolValue { fields.removeAll(keepingCapacity: true) }
        for key in Self.textKeys.union(Self.numberKeys).union(Self.flagKeys) {
            guard let value = payload[key] else { continue }
            if value is NSNull { fields[key] = nil }
            else if Self.textKeys.contains(key), let text = value as? String { fields[key] = .text(String(text.prefix(2000))) }
            else if Self.numberKeys.contains(key), let number = value as? NSNumber,
                    CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { fields[key] = .number(number.doubleValue) }
            else if Self.flagKeys.contains(key), let number = value as? NSNumber,
                    CFGetTypeID(number) == CFBooleanGetTypeID() { fields[key] = .flag(number.boolValue) }
            else { fields[key] = nil }
        }
        if let value = payload["artworkData"] {
            if let encoded = value as? String, !encoded.isEmpty, encoded.utf8.count <= 5_600_000 {
                let hash = SHA256.hash(data: Data(encoded.utf8))
                if hash != artworkHash {
                    let decoded = Data(base64Encoded: encoded)
                    artwork = decoded.flatMap { $0.count <= 4 * 1024 * 1024 ? $0 : nil }
                    artworkHash = artwork == nil ? nil : hash
                    artworkID = artwork == nil ? nil : UUID()
                }
            } else { clearArtwork() }
        } else if !diff.boolValue { clearArtwork() }
        guard let title = text("title"), !title.isEmpty else {
            lastSnapshot = nil
            anchorElapsed = nil
            anchorTimestamp = nil
            return nil
        }
        let duration = number("duration").flatMap { $0 > 0 && $0 <= 365 * 86400 ? $0 : nil }
        let elapsed = number("elapsedTime").flatMap { $0 >= 0 && $0 <= 365 * 86400 ? $0 : nil }
        let timestamp = text("timestamp").flatMap { try? Date.ISO8601FormatStyle().parse($0) } ?? now
        if !diff.boolValue || payload["elapsedTime"] != nil || payload["timestamp"] != nil {
            anchorElapsed = elapsed
            anchorTimestamp = timestamp
        } else if payload["playing"] != nil || payload["playbackRate"] != nil {
            // The adapter's IsPlaying notification may contain only this flag.
            // Freeze the old clock at the transition, then resume from that
            // point, so a pause neither rewinds nor adds time spent paused.
            anchorElapsed = lastSnapshot?.elapsed(at: now)
            anchorTimestamp = now
        }
        let snapshot = MediaSnapshot(source: text("bundleIdentifier").flatMap(ApplicationID.init(rawValue:)),
                     title: title, artist: text("artist") ?? "", album: text("album") ?? "",
                     playing: flag("playing") ?? false, duration: duration, elapsed: anchorElapsed,
                     sampledAt: anchorTimestamp ?? now, rate: min(max(number("playbackRate") ?? 1, 0.25), 4),
                     canSkip: !(flag("prohibitsSkip") ?? false), artwork: artwork, artworkID: artworkID)
        lastSnapshot = snapshot
        return snapshot
    }

    private mutating func clearArtwork() { artwork = nil; artworkID = nil; artworkHash = nil }
    private func text(_ key: String) -> String? { if case .text(let value) = fields[key] { return value }; return nil }
    private func number(_ key: String) -> Double? { if case .number(let value) = fields[key] { return value }; return nil }
    private func flag(_ key: String) -> Bool? { if case .flag(let value) = fields[key] { return value }; return nil }
}
