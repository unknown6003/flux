import Foundation

public struct ClipboardColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public static func parse(_ text: String) -> Self? {
        guard text.first == "#" else { return nil }
        let bytes = Array(text.dropFirst().utf8)
        guard [3, 4, 6, 8].contains(bytes.count), bytes.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        let expanded = bytes.count <= 4 ? bytes.flatMap { [$0, $0] } : bytes
        let values = stride(from: 0, to: expanded.count, by: 2).compactMap {
            UInt8(String(decoding: expanded[$0..<($0 + 2)], as: UTF8.self), radix: 16).map { Double($0) / 255 }
        }
        guard values.count >= 3 else { return nil }
        return .init(red: values[0], green: values[1], blue: values[2], alpha: values.count == 4 ? values[3] : 1)
    }
}

public enum ClipboardPayload: Equatable, Sendable {
    case text(String, SavedClipboardKind)
    case files([URL])
    /// Full encoded bytes are optional when they exceeded the per-entry or total budget.
    case image(bytes: Data?, thumbnail: Data?, width: Int, height: Int)
    case unsupported
}

public struct ClipboardRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public fileprivate(set) var payload: ClipboardPayload

    public var preview: String {
        switch payload {
        case .text(let text, _): String(text.prefix(200)).components(separatedBy: .newlines).joined(separator: " ")
        case .files(let urls): urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        case .image(_, _, let width, let height): "Image \(width) × \(height)"
        case .unsupported: "Unsupported content"
        }
    }

    public var browserURL: URL? {
        guard case .text(let text, .url) = payload,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    public var canCopy: Bool {
        switch payload {
        case .image(let bytes, _, _, _): bytes != nil
        case .unsupported: false
        default: true
        }
    }
}

/// Value-only history. It owns no pasteboard, timer, file or image decoder.
public struct ClipboardHistory: Sendable {
    public static let maximumTextCharacters = 100_000
    public static let maximumImageBytes = 8 * 1024 * 1024
    public static let imageByteBudget = 48 * 1024 * 1024
    public static let maximumThumbnailBytes = 64 * 1024
    public private(set) var records: [ClipboardRecord] = []

    public init() {}

    public mutating func capture(_ payload: ClipboardPayload, at date: Date, id: UUID = UUID()) {
        let bounded = Self.bounded(payload)
        guard records.first?.payload != bounded else { return }
        records.insert(.init(id: id, capturedAt: date, payload: bounded), at: 0)
        records = Array(records.prefix(ClipboardArchive.maximumEntries))
        var used = 0
        for index in records.indices {
            guard case .image(let bytes?, let thumbnail, let width, let height) = records[index].payload else { continue }
            if used + bytes.count <= Self.imageByteBudget { used += bytes.count }
            else { records[index].payload = .image(bytes: nil, thumbnail: thumbnail, width: width, height: height) }
        }
    }

    public mutating func remove(_ id: UUID) { records.removeAll { $0.id == id } }
    public mutating func clear() { records.removeAll() }

    public mutating func restore(_ entries: [SavedClipboardEntry]) {
        let existing = Set(savedEntries.map(\.text))
        for entry in entries where !existing.contains(entry.text) {
            records.append(.init(id: UUID(), capturedAt: entry.capturedAt, payload: .text(entry.text, entry.kind)))
        }
        records.sort { $0.capturedAt > $1.capturedAt }
        records = Array(records.prefix(ClipboardArchive.maximumEntries))
    }

    public var savedEntries: [SavedClipboardEntry] {
        records.compactMap {
            guard case .text(let text, let kind) = $0.payload else { return nil }
            return .init(capturedAt: $0.capturedAt, kind: kind, text: text)
        }
    }

    public static func classify(_ text: String) -> SavedClipboardKind {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ClipboardColor.parse(value) != nil { return .color }
        if let url = URL(string: value), url.scheme != nil, url.host != nil { return .url }
        return .text
    }

    private static func bounded(_ payload: ClipboardPayload) -> ClipboardPayload {
        switch payload {
        case .text(let text, let kind):
            return .text(text.count > maximumTextCharacters ? String(text.prefix(maximumTextCharacters)) + "…" : text, kind)
        case .files(let urls):
            let accepted = Array(urls.filter(\.isFileURL).prefix(1000))
            return accepted.isEmpty ? .unsupported : .files(accepted)
        case .image(let bytes, let thumbnail, let width, let height):
            return .image(bytes: bytes.flatMap { $0.count <= maximumImageBytes ? $0 : nil },
                          thumbnail: thumbnail.flatMap { $0.count <= maximumThumbnailBytes ? $0 : nil },
                          width: max(0, width), height: max(0, height))
        case .unsupported: return payload
        }
    }
}
