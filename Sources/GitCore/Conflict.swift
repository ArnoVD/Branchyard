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

    /// One line of the result: picked from a side, plain text both sides share, or a conflict
    /// with nothing picked yet.
    public enum OutputLine: Sendable, Equatable {
        case text(String)
        case picked(String, ConflictPicks.Side, hunk: Int)
        case unresolved(hunk: Int)
    }

    /// The result with `picks` applied. In each conflict, the lines of the side picked first come
    /// first; each side's lines keep their order.
    public func output(_ picks: ConflictPicks) -> [OutputLine] {
        var out: [OutputLine] = []
        for segment in segments {
            switch segment {
            case .text(let lines):
                out += lines.map(OutputLine.text)
            case .conflict(let hunk):
                guard picks.isResolved(hunk.id) else { out.append(.unresolved(hunk: hunk.id)); continue }
                let order: [ConflictPicks.Side] = picks.firstSide(hunk.id) == .theirs ? [.theirs, .ours] : [.ours, .theirs]
                for side in order {
                    let lines = side == .ours ? hunk.ours : hunk.theirs
                    for (i, line) in lines.enumerated() where picks.contains(.init(hunk: hunk.id, side: side, index: i)) {
                        out.append(.picked(line, side, hunk: hunk.id))
                    }
                }
            }
        }
        return out
    }

    /// The file contents with `picks` applied, or nil while a conflict has nothing picked.
    public func resolved(_ picks: ConflictPicks) -> String? {
        var lines: [String] = []
        for line in output(picks) {
            switch line {
            case .text(let text), .picked(let text, _, _): lines.append(text)
            case .unresolved: return nil
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Which lines of each conflict go into the result, picked side by side (A = ours, B = theirs).
public struct ConflictPicks: Sendable, Equatable {
    public enum Side: Sendable, Hashable { case ours, theirs }

    public struct Line: Hashable, Sendable {
        public let hunk: Int
        public let side: Side
        /// The line within that side of the conflict. `Line.whole` stands for a side with no lines,
        /// so picking "nothing from this side" still resolves the conflict.
        public let index: Int
        public static let whole = -1
        public init(hunk: Int, side: Side, index: Int) {
            self.hunk = hunk
            self.side = side
            self.index = index
        }
    }

    public private(set) var lines: Set<Line> = []
    private var first: [Int: Side] = [:]

    public init() {}

    public var isEmpty: Bool { lines.isEmpty }
    public func contains(_ line: Line) -> Bool { lines.contains(line) }
    public func isResolved(_ hunk: Int) -> Bool { lines.contains { $0.hunk == hunk } }
    /// The side picked first in a conflict; its lines come first in the result.
    public func firstSide(_ hunk: Int) -> Side? { first[hunk] }

    public mutating func toggle(_ line: Line) {
        set([line], picked: !lines.contains(line))
    }

    public mutating func set(_ toSet: [Line], picked: Bool) {
        for line in toSet {
            if picked {
                if !isResolved(line.hunk) { first[line.hunk] = line.side }
                lines.insert(line)
            } else {
                lines.remove(line)
                if first[line.hunk] == line.side, !lines.contains(where: { $0.hunk == line.hunk && $0.side == line.side }) {
                    first[line.hunk] = isResolved(line.hunk) ? (line.side == .ours ? .theirs : .ours) : nil
                }
            }
        }
    }

    /// Every line of `side` in `hunk` (or the empty side itself).
    public static func all(_ side: Side, of hunk: ConflictFile.Hunk) -> [Line] {
        let count = side == .ours ? hunk.ours.count : hunk.theirs.count
        return count == 0 ? [Line(hunk: hunk.id, side: side, index: Line.whole)]
            : (0..<count).map { Line(hunk: hunk.id, side: side, index: $0) }
    }
}
