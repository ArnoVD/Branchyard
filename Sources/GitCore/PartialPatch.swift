import Foundation

/// Builds a patch from some of the changed lines in a file's diff, for staging, unstaging or
/// discarding single hunks or lines.
public enum PartialPatch {
    /// Which side of the diff the patch is applied to.
    public enum Direction: Sendable {
        /// Applied as is to the diff's old side: stage lines of an unstaged diff.
        case forward
        /// Applied with `-R` to the diff's new side: unstage lines of a staged diff, or
        /// discard lines of an unstaged diff.
        case reverse
    }

    /// The patch for the `selected` added/removed lines of `lines` (one file's diff, as
    /// `Parsers.diff` returns it), or nil when none of them is selected.
    ///
    /// Lines left out turn into what the other side already has: an unselected removed line
    /// stays as context going forward (the old side still has it), an unselected added line
    /// stays as context in reverse (the new side has it).
    public static func make(path: String, lines: [DiffLine], selected: Set<Int>, direction: Direction) -> String? {
        var hunks: [String] = []
        // How far the side the patch is not applied to has drifted, from earlier hunks.
        var shift = 0
        var i = lines.startIndex
        while i < lines.endIndex {
            guard lines[i].kind == .hunk else { i += 1; continue }
            let (oldStart, newStart) = starts(lines[i].text)
            var body: [String] = []
            var oldCount = 0, newCount = 0, changed = false
            var lastKept = false
            i += 1
            while i < lines.endIndex, lines[i].kind != .hunk, lines[i].kind != .fileHeader {
                let line = lines[i]
                let text = String(line.text.dropFirst())
                let picked = selected.contains(line.id)
                var out: String?
                switch line.kind {
                case .context:
                    out = " " + text
                case .added where picked, .removed where picked:
                    out = line.text
                    changed = true
                case .added:
                    out = direction == .reverse ? " " + text : nil
                case .removed:
                    out = direction == .forward ? " " + text : nil
                case .meta where line.text.hasPrefix("\\"):
                    // "\ No newline at end of file" belongs to the line before it.
                    if lastKept { body.append(line.text) }
                    i += 1
                    continue
                default:
                    break
                }
                if let out {
                    body.append(out)
                    switch out.first {
                    case "+": newCount += 1
                    case "-": oldCount += 1
                    default: oldCount += 1; newCount += 1
                    }
                }
                lastKept = out != nil
                i += 1
            }
            guard changed else { continue }
            // The side the patch is applied to keeps its own line numbers.
            let old: Int, new: Int
            switch direction {
            case .forward: old = oldStart; new = oldStart + shift
            case .reverse: new = newStart; old = newStart + shift
            }
            shift += direction == .forward ? newCount - oldCount : oldCount - newCount
            hunks.append("@@ -\(start(old, oldCount)),\(oldCount) +\(start(new, newCount)),\(newCount) @@\n"
                         + body.joined(separator: "\n"))
        }
        guard !hunks.isEmpty else { return nil }
        return "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n" + hunks.joined(separator: "\n") + "\n"
    }

    /// The ids of every added/removed line.
    public static func changedIDs(_ lines: [DiffLine]) -> Set<Int> {
        Set(lines.filter { $0.kind == .added || $0.kind == .removed }.map(\.id))
    }

    /// An empty side starts at the line before (0); otherwise at line 1 or later.
    private static func start(_ base: Int, _ count: Int) -> Int {
        count == 0 ? max(base - 1, 0) : max(base, 1)
    }

    /// "@@ -12,5 +12,7 @@" → (12, 12)
    private static func starts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func value(_ index: Int) -> Int {
            guard parts.count > index else { return 0 }
            return Int(parts[index].dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (value(1), value(2))
    }
}

extension Repository {
    /// Stages the `selected` lines of an unstaged diff.
    public func stageLines(_ selected: Set<Int>, of lines: [DiffLine], path: String) async throws {
        guard let patch = PartialPatch.make(path: path, lines: lines, selected: selected, direction: .forward) else { return }
        try await applyPatch(patch, cached: true)
    }

    /// Takes the `selected` lines of a staged diff back out of the index.
    public func unstageLines(_ selected: Set<Int>, of lines: [DiffLine], path: String) async throws {
        guard let patch = PartialPatch.make(path: path, lines: lines, selected: selected, direction: .reverse) else { return }
        try await applyPatch(patch, cached: true, reverse: true)
    }

    /// Throws away the `selected` lines of an unstaged diff. Returns the patch that puts them
    /// back (`applyPatch(patch)`), for undo.
    @discardableResult
    public func discardLines(_ selected: Set<Int>, of lines: [DiffLine], path: String) async throws -> String? {
        guard let patch = PartialPatch.make(path: path, lines: lines, selected: selected, direction: .reverse) else { return nil }
        try await applyPatch(patch, reverse: true)
        return patch
    }
}
