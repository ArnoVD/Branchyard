import SwiftUI
import AppKit
import GitCore

/// A button on a hunk's `@@` row.
struct HunkAction {
    let title: String
    let prominent: Bool
    let run: () -> Void
}

/// Hunk and Inline View (and File View) as one AppKit text view, so a mouse drag selects across
/// lines: SwiftUI text selection stops at the end of each `Text`. Line numbers and the +/- column
/// sit in a gutter beside it, where clicking or dragging picks changed lines for line staging.
struct DiffTextView: NSViewRepresentable {
    let rows: [DiffLine]
    let style: DiffStyle
    var picked: Set<Int> = []
    /// Changes when the hunk buttons change for the same rows (staged vs unstaged).
    var hunkKey = ""
    /// Mouse-down in the gutter on a changed line (Shift held?). nil: lines can't be picked.
    var onPick: ((DiffLine, Bool) -> Void)? = nil
    /// Dragging in the gutter: from the line under the mouse-down to the line under the mouse now.
    var onPickDrag: ((DiffLine, DiffLine) -> Void)? = nil
    var hunkActions: (DiffLine) -> [HunkAction] = { _ in [] }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let text = DiffNSTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.textContainer?.lineFragmentPadding = 0
        text.layoutManager?.allowsNonContiguousLayout = true
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        scroll.documentView = text

        let gutter = DiffGutter(scrollView: scroll, orientation: .verticalRuler)
        gutter.text = text
        gutter.clientView = text
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        let coordinator = context.coordinator
        coordinator.text = text
        coordinator.gutter = gutter
        gutter.onPick = { [weak coordinator] row, shift in coordinator?.pick(row, shift: shift) }
        gutter.onDrag = { [weak coordinator] from, to in coordinator?.drag(from, to) }
        // The gutter follows the text when it scrolls.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let shown = rows.filter { $0.kind != .fileHeader }
        let key = Coordinator.Key(rows: shown, style: style.key + "|" + hunkKey, pickable: onPick != nil)
        if key != coordinator.key {
            coordinator.key = key
            coordinator.rows = shown
            coordinator.show(shown, style: style, in: scroll)
        }
        coordinator.showPicked(picked)
    }

    final class Coordinator: NSObject {
        struct Key: Equatable {
            let rows: [DiffLine]
            let style: String
            let pickable: Bool
        }

        var parent: DiffTextView?
        var key: Key?
        var rows: [DiffLine] = []
        weak var text: DiffNSTextView?
        weak var gutter: DiffGutter?

        @objc func scrolled() { gutter?.needsDisplay = true }

        func pick(_ row: Int, shift: Bool) {
            guard rows.indices.contains(row), let onPick = parent?.onPick else { return }
            onPick(rows[row], shift)
        }

        func drag(_ from: Int, _ to: Int) {
            guard rows.indices.contains(from), rows.indices.contains(to) else { return }
            parent?.onPickDrag?(rows[from], rows[to])
        }

        func show(_ rows: [DiffLine], style: DiffStyle, in scroll: NSScrollView) {
            guard let text, let gutter, let container = text.textContainer else { return }
            let font = style.nsFont
            let lineHeight = (style.size * 1.5).rounded()
            let natural = NSLayoutManager().defaultLineHeight(for: font)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.tabStops = []
            paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(style.tabSize)
            let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph,
                                                       .baselineOffset: (lineHeight - natural) / 2]
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

            let content = NSMutableAttributedString()
            var starts: [Int] = []
            for (i, line) in rows.enumerated() {
                starts.append(content.length)
                let code = style.code(line)
                var attributes = base
                if DiffShaping.isBody(line) {
                    attributes[.foregroundColor] = NSColor.labelColor
                    let colored = SyntaxHighlighter.highlight(code, language: style.language, palette: style.palette)
                    for run in colored.runs {
                        var part = attributes
                        if let color = run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] {
                            part[.foregroundColor] = NSColor(color)
                        }
                        if run.inlinePresentationIntent?.contains(.emphasized) == true { part[.font] = italic }
                        content.append(NSAttributedString(string: String(colored[run.range].characters), attributes: part))
                    }
                } else {
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                    content.append(NSAttributedString(string: code, attributes: attributes))
                }
                if i < rows.count - 1 { content.append(NSAttributedString(string: "\n", attributes: base)) }
            }

            scroll.hasHorizontalScroller = !style.wrap
            text.isHorizontallyResizable = !style.wrap
            container.widthTracksTextView = style.wrap
            container.containerSize = NSSize(width: style.wrap ? scroll.contentSize.width : .greatestFiniteMagnitude,
                                             height: .greatestFiniteMagnitude)
            text.textStorage?.setAttributedString(content)
            text.rows = rows
            text.rowStarts = starts
            text.lineHeight = lineHeight
            text.setAccessories(rows.indices.compactMap { i in
                let actions = rows[i].kind == .hunk ? parent?.hunkActions(rows[i]) ?? [] : []
                return actions.isEmpty ? nil : (i, NSHostingView(rootView: HunkButtons(actions: actions)))
            })

            gutter.style = style
            gutter.paragraph = paragraph
            gutter.baselineOffset = (lineHeight - natural) / 2
            gutter.pickable = parent?.onPick != nil
            gutter.ruleThickness = gutter.width
            gutter.window?.invalidateCursorRects(for: gutter)
        }

        func showPicked(_ ids: Set<Int>) {
            guard let text, let gutter else { return }
            let picked = Set(rows.indices.filter { ids.contains(rows[$0].id) })
            guard picked != text.picked else { return }
            text.picked = picked
            text.needsDisplay = true
            gutter.needsDisplay = true
        }
    }
}

private struct HunkButtons: View {
    let actions: [HunkAction]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions.indices, id: \.self) { i in
                HunkButton(title: actions[i].title, prominent: actions[i].prominent, action: actions[i].run)
            }
        }
    }
}

/// The diff's text, with each line's color painted the full width behind it.
final class DiffNSTextView: NSTextView {
    var rows: [DiffLine] = []
    /// Where each row starts in the text (UTF-16 offsets).
    var rowStarts: [Int] = []
    /// Rows picked for line staging (indices into `rows`).
    var picked: Set<Int> = []
    var lineHeight: CGFloat = 18
    private var accessories: [(row: Int, view: NSView)] = []

    func background(of row: Int) -> NSColor? {
        if picked.contains(row) { return NSColor(Color.byAccent.opacity(0.28)) }
        switch rows[row].kind {
        case .added: return NSColor(DiffColors.added)
        case .removed: return NSColor(DiffColors.removed)
        case .hunk: return NSColor(Color.byAccent.opacity(0.10))
        default: return nil
        }
    }

    /// The row a character belongs to.
    func row(at character: Int) -> Int {
        var low = 0, high = rowStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rowStarts[mid] <= character { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    /// A row's height and position (all its wrapped lines), in this view's coordinates.
    func rowRect(_ row: Int) -> NSRect {
        guard let layoutManager, let textContainer, rowStarts.indices.contains(row) else { return .zero }
        let end = row + 1 < rowStarts.count ? rowStarts[row + 1] - 1 : (textStorage?.length ?? 0)
        let range = NSRange(location: rowStarts[row], length: max(0, end - rowStarts[row]))
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect: NSRect
        if glyphs.length == 0 {
            // An empty last line has no glyphs; it lives in the extra line fragment.
            if glyphs.location >= layoutManager.numberOfGlyphs {
                layoutManager.ensureLayout(for: textContainer)
                rect = layoutManager.extraLineFragmentRect
            } else {
                rect = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            }
        } else {
            let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = layoutManager.lineFragmentRect(forGlyphAt: glyphs.upperBound - 1, effectiveRange: nil)
            rect = first.union(last)
        }
        rect.origin.y += textContainerOrigin.y
        rect.origin.x = 0
        rect.size.width = bounds.width
        return rect
    }

    /// Rows that show inside `rect` (this view's coordinates).
    func rows(in rect: NSRect) -> ClosedRange<Int>? {
        guard let layoutManager, let textContainer, !rowStarts.isEmpty else { return nil }
        let area = rect.offsetBy(dx: 0, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: area, in: textContainer)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = row(at: chars.location)
        var last = row(at: max(chars.location, chars.upperBound - 1))
        if chars.upperBound >= (textStorage?.length ?? 0) { last = rowStarts.count - 1 }
        return first...last
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let visible = rows(in: rect) else { return }
        for row in visible {
            guard let color = background(of: row) else { continue }
            color.setFill()
            rowRect(row).fill(using: .sourceOver)
        }
    }

    // MARK: hunk buttons

    func setAccessories(_ views: [(Int, NSView)]) {
        accessories.forEach { $0.view.removeFromSuperview() }
        accessories = views.map { (row: $0.0, view: $0.1) }
        accessories.forEach { addSubview($0.view) }
        placeAccessories()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !accessories.isEmpty { needsLayout = true }
    }

    override func layout() {
        super.layout()
        placeAccessories()
    }

    /// Hunk buttons sit right after the `@@` text, centered on its line.
    private func placeAccessories() {
        guard let layoutManager else { return }
        for (row, view) in accessories where rowStarts.indices.contains(row) {
            let glyph = layoutManager.glyphIndexForCharacter(at: rowStarts[row])
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let line = rowRect(row)
            let size = view.fittingSize
            view.frame = NSRect(x: used.maxX + textContainerOrigin.x + 12,
                                y: line.minY + (min(line.height, lineHeight) - size.height) / 2,
                                width: size.width, height: size.height)
        }
    }
}

/// Line numbers and the +/- column; ✓ marks lines picked for line staging.
final class DiffGutter: NSRulerView {
    weak var text: DiffNSTextView?
    var style: DiffStyle?
    var paragraph = NSParagraphStyle()
    var baselineOffset: CGFloat = 0
    var pickable = false {
        didSet { toolTip = pickable ? "Click to pick a line, Shift-click or drag for a range" : nil }
    }
    var onPick: ((Int, Bool) -> Void)?
    var onDrag: ((Int, Int) -> Void)?
    private var dragStart: Int?
    private var dragLast: Int?

    private static let signWidth: CGFloat = 16

    private var columns: Int {
        guard let style, style.lineNumbers else { return 0 }
        return style.fileMode ? 1 : 2
    }

    var width: CGFloat {
        CGFloat(columns) * ((style?.numberWidth ?? 34) + 6) + Self.signWidth
    }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { width }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Color.byPane).setFill()
        bounds.fill()
        guard let text, let style, let visible = text.rows(in: text.visibleRect) else { return }
        let numberWidth = style.numberWidth
        let accent = NSColor(Color.byAccent)
        for row in visible {
            let line = text.rows[row]
            var frame = convert(text.rowRect(row), from: text)
            frame.origin.x = 0
            frame.size.width = bounds.width
            if let color = text.background(of: row) {
                color.setFill()
                frame.fill(using: .sourceOver)
            }
            let picked = text.picked.contains(row)
            if picked {
                accent.setFill()
                NSRect(x: 0, y: frame.minY, width: 3, height: frame.height).fill()
            }
            let first = NSRect(x: 0, y: frame.minY, width: 0, height: text.lineHeight)
            var x: CGFloat = 0
            let numbers = columns == 1 ? [line.newNumber ?? line.oldNumber] : columns == 2 ? [line.oldNumber, line.newNumber] : []
            for number in numbers {
                if let number {
                    label(String(number), color: .tertiaryLabelColor, alignment: .right,
                          in: NSRect(x: x, y: first.minY, width: numberWidth, height: first.height))
                }
                x += numberWidth + 6
            }
            let sign = picked ? "✓" : line.kind == .added ? "+" : line.kind == .removed ? "-" : ""
            if !sign.isEmpty {
                label(sign, color: picked ? accent : .secondaryLabelColor, alignment: .center,
                      in: NSRect(x: x, y: first.minY, width: Self.signWidth, height: first.height))
            }
        }
    }

    private func label(_ string: String, color: NSColor, alignment: NSTextAlignment, in rect: NSRect) {
        guard let font = style?.nsFont else { return }
        let paragraph = (self.paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.alignment = alignment
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color,
                                                        .paragraphStyle: paragraph, .baselineOffset: baselineOffset])
            .draw(in: rect)
    }

    // MARK: picking lines

    /// The changed row under the mouse, if lines can be picked.
    private func pickableRow(_ event: NSEvent) -> Int? {
        guard pickable, let text, let visible = text.rows(in: text.visibleRect) else { return nil }
        let point = text.convert(event.locationInWindow, from: nil)
        guard let row = visible.first(where: { text.rowRect($0).insetBy(dx: 0, dy: -0.5).contains(NSPoint(x: 1, y: point.y)) }),
              text.rows[row].kind == .added || text.rows[row].kind == .removed else { return nil }
        return row
    }

    override func mouseDown(with event: NSEvent) {
        guard let row = pickableRow(event) else { return }
        dragStart = row
        dragLast = row
        onPick?(row, event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        text?.autoscroll(with: event)
        guard let row = pickableRow(event), row != dragLast else { return }
        dragLast = row
        onDrag?(start, row)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        dragLast = nil
    }

    override func resetCursorRects() {
        if pickable { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
