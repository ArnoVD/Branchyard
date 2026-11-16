import Foundation

extension String {
    /// The text split at every "\n", with each line's "\r" (Windows line endings) left on it.
    ///
    /// Swift treats "\r\n" as a single Character, so `split(separator: "\n")` doesn't see the
    /// line breaks of a CRLF file at all and returns the whole text as one line. This splits on
    /// the "\n" scalar instead.
    public func splitLines(omittingEmpty: Bool = false) -> [String] {
        unicodeScalars.split(separator: "\n", omittingEmptySubsequences: omittingEmpty)
            .map { String(Substring($0)) }
    }

    /// The line without the "\r" a Windows line ending leaves at its end.
    public var droppingCR: String {
        unicodeScalars.last == "\r" ? String(Substring(unicodeScalars.dropLast())) : self
    }

    /// Whether the line ends with a "\r" from a Windows line ending.
    public var endsWithCR: Bool { unicodeScalars.last == "\r" }
}
