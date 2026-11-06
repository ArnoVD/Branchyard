import Foundation

/// A file containing `<<<<<<<` / `=======` / `>>>>>>>` conflict markers, split into
/// plain text and conflict hunks so each hunk can be resolved separately.
public struct ConflictFile: Sendable {
    public enum Segment: Sendable {
        case text([String])
        case conflict(Hunk)
    }

    public struct Hunk: Identifiable, Sendable {
        public let id: Int
        public let ours: [String]
        public let base: [String]?      // present with merge.conflictStyle=diff3/zdiff3
        public let theirs: [String]
        public let oursLabel: String
        public let theirsLabel: String
    }

    public enum Resolution: String, CaseIterable, Identifiable, Sendable {
        case ours, theirs, oursThenTheirs, theirsThenOurs
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .ours: return "Ours"
            case .theirs: return "Theirs"
            case .oursThenTheirs: return "Both (ours first)"
            case .theirsThenOurs: return "Both (theirs first)"
            }
        }
    }

    public let segments: [Segment]

    public var hunks: [Hunk] {
        segments.compactMap { if case .conflict(let h) = $0 { return h } else { return nil } }
    }

    public init(contents: String) {
        var segments: [Segment] = []
        var plain: [String] = []
        var ours: [String] = [], base: [String] = [], theirs: [String] = []
        var raw: [String] = []          // original lines of the open hunk, in case it is never closed
        var oursLabel = "", theirsLabel = ""
        var hasBase = false
        enum State { case text, ours, base, theirs }
        var state = State.text
        var nextID = 0

        func isMarker(_ line: String, _ marker: String) -> Bool {
            line == marker || line.hasPrefix(marker + " ") || line == marker + "\r"
        }

        for line in contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            switch state {
            case .text:
                if isMarker(line, "<<<<<<<") {
                    if !plain.isEmpty { segments.append(.text(plain)); plain = [] }
                    oursLabel = String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                    ours = []; base = []; theirs = []; raw = [line]; hasBase = false
                    state = .ours
                } else {
                    plain.append(line)
                }
            case .ours, .base:
                raw.append(line)
                if isMarker(line, "|||||||") {
                    hasBase = true
                    state = .base
                } else if isMarker(line, "=======") {
                    state = .theirs
                } else if state == .ours {
                    ours.append(line)
                } else {
                    base.append(line)
                }
            case .theirs:
                raw.append(line)
                if isMarker(line, ">>>>>>>") {
                    theirsLabel = String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                    segments.append(.conflict(Hunk(id: nextID, ours: ours, base: hasBase ? base : nil,
                                                   theirs: theirs, oursLabel: oursLabel, theirsLabel: theirsLabel)))
                    nextID += 1
                    state = .text
                } else {
                    theirs.append(line)
                }
            }
        }
        // An unterminated hunk isn't a real conflict: keep its lines as plain text.
        if state != .text { plain.append(contentsOf: raw) }
        if !plain.isEmpty { segments.append(.text(plain)) }
        self.segments = segments
    }

    /// The file contents with every hunk resolved, or nil while any hunk has no choice yet.
    public func resolved(with choices: [Int: Resolution]) -> String? {
        var out: [String] = []
        for segment in segments {
            switch segment {
            case .text(let lines):
                out.append(contentsOf: lines)
            case .conflict(let hunk):
                guard let choice = choices[hunk.id] else { return nil }
                switch choice {
                case .ours: out.append(contentsOf: hunk.ours)
                case .theirs: out.append(contentsOf: hunk.theirs)
                case .oursThenTheirs: out.append(contentsOf: hunk.ours + hunk.theirs)
                case .theirsThenOurs: out.append(contentsOf: hunk.theirs + hunk.ours)
                }
            }
        }
        return out.joined(separator: "\n")
    }
}
