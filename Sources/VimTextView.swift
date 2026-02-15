import AppKit

/// Custom NSTextView that routes keystrokes through VimBridge in normal/visual modes
/// and falls through to standard NSTextView behavior in insert mode.
final class VimTextView: NSTextView {
    var vimBridge: VimBridge?
    var vimEnabled = true

    private var isSyncingFromVim = false
    private var blockCursorRect: NSRect?
    private var lastGPressTime: TimeInterval = 0

    var onEscapeInNormalMode: (() -> Void)?

    override var insertionPointColor: NSColor! {
        get {
            // Hide default cursor in normal mode (we draw our own block)
            if vimBridge?.mode != .insert { return .clear }
            return super.insertionPointColor
        }
        set { super.insertionPointColor = newValue }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if vimBridge?.mode == .insert {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBlockCursor()
    }

    /// Draws a translucent block cursor at the vim cursor position.
    /// Uses font metrics for accurate character width instead of hardcoded values.
    private func drawBlockCursor() {
        guard let bridge = vimBridge, bridge.mode != .insert else { return }

        let (line, col) = bridge.getCursorPosition()
        let offset = offsetForPosition(line: line, column: col)

        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return }

        let charIndex = min(offset, max(0, string.count - 1))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)

        let lineFragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphIndex)

        // Measure character width from the actual font instead of hardcoding
        let charWidth = measureCharWidth()
        let charHeight = lineFragmentRect.height

        let cursorRect = NSRect(
            x: lineFragmentRect.origin.x + location.x + textContainerInset.width,
            y: lineFragmentRect.origin.y + textContainerInset.height,
            width: min(charWidth, charWidth),
            height: charHeight
        )

        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: cursorRect).fill()

        blockCursorRect = cursorRect
    }

    /// @returns Width of a single character in the current monospace font.
    private func measureCharWidth() -> CGFloat {
        let currentFont = font ?? .monospacedSystemFont(ofSize: 14, weight: .regular)
        let attrStr = NSAttributedString(string: "M", attributes: [.font: currentFont])
        return attrStr.size().width
    }

    func updateCursor() {
        if let rect = blockCursorRect {
            setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard vimEnabled, let bridge = vimBridge else {
            super.keyDown(with: event)
            return
        }

        // In insert mode, most keys pass through to NSTextView
        // except Escape which returns to normal mode
        if bridge.mode == .insert {
            if event.keyCode == 53 { // Escape
                bridge.syncFromTextView(string)
                _ = bridge.handleKey(event)
                let (line, col) = bridge.getCursorPosition()
                let cursorOffset = offsetForPosition(line: line, column: col)
                setSelectedRange(NSRange(location: cursorOffset, length: 0))
                updateCursor()
                return
            }
            super.keyDown(with: event)
            return
        }

        if handleScrollKeys(event) {
            return
        }

        if bridge.mode == .normal, handleNormalModeNavigation(event) {
            return
        }

        // Escape in normal mode closes the panel
        if bridge.mode == .normal && event.keyCode == 53 {
            onEscapeInNormalMode?()
            return
        }

        // Sync current text TO vim before processing command
        // so vim has the latest text for operations like delete, yank, etc.
        bridge.syncFromTextView(string)

        let handled = bridge.handleKey(event)

        if handled {
            syncFromVimBuffer()
        } else {
            super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        vimLog("[VimTextView] becomeFirstResponder ok=\(ok)")
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        vimLog("[VimTextView] resignFirstResponder ok=\(ok)")
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        DispatchQueue.main.async {
            window.makeFirstResponder(self)
        }
    }

    /// Handles Ctrl+U (half page up) and Ctrl+D (half page down).
    /// Moves both the scroll viewport and the vim cursor position.
    /// @returns true if the event was a scroll key and was handled.
    private func handleScrollKeys(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.control) else { return false }

        if event.keyCode == 32 { // kVK_ANSI_U
            scrollHalfPage(direction: -1)
            return true
        }
        if event.keyCode == 2 { // kVK_ANSI_D
            scrollHalfPage(direction: 1)
            return true
        }

        return false
    }

    /// Scrolls the view by half a page and moves the vim cursor to match.
    /// @param direction -1 for up, 1 for down.
    private func scrollHalfPage(direction: CGFloat) {
        guard let scrollView = enclosingScrollView, let bridge = vimBridge else { return }
        let contentView = scrollView.contentView
        let visibleHeight = contentView.bounds.height
        let delta = visibleHeight * 0.5 * direction

        var newOrigin = contentView.bounds.origin
        newOrigin.y += delta

        if let documentView = scrollView.documentView {
            let maxY = max(0, documentView.bounds.height - visibleHeight)
            newOrigin.y = min(max(0, newOrigin.y), maxY)
        } else {
            newOrigin.y = max(0, newOrigin.y)
        }

        contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(contentView)

        // Move vim cursor by the number of lines scrolled
        let lineHeight = layoutManager?.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 14, weight: .regular)) ?? 17.0
        let lineDelta = Int(round(delta / lineHeight))
        let (currentLine, currentCol) = bridge.getCursorPosition()
        let lines = string.components(separatedBy: "\n")
        let newLine = max(1, min(lines.count, currentLine + lineDelta))
        let lineLen = lines[newLine - 1].count
        let newCol = min(currentCol, max(0, lineLen > 0 ? lineLen - 1 : 0))
        bridge.setCursorPosition(line: newLine, column: newCol)

        let offset = offsetForPosition(line: newLine, column: newCol)
        setSelectedRange(NSRange(location: offset, length: 0))
        updateCursor()
    }

    /// Handles gg (go to top) and G (go to bottom) in normal mode.
    /// @returns true if the event was handled.
    private func handleNormalModeNavigation(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 5, modifiers.contains(.shift) { // G
            moveCursorToEnd()
            return true
        }
        if event.keyCode == 5, modifiers.isDisjoint(with: [.command, .control, .option, .shift]) { // g
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastGPressTime < 0.4 {
                moveCursorToStart()
                lastGPressTime = 0
                return true
            }
            lastGPressTime = now
        }
        return false
    }

    private func moveCursorToStart() {
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
        syncCursorToVim()
        updateCursor()
    }

    private func moveCursorToEnd() {
        let end = string.count
        setSelectedRange(NSRange(location: end, length: 0))
        scrollRangeToVisible(NSRange(location: max(0, end - 1), length: 0))
        syncCursorToVim()
        updateCursor()
    }

    func syncToVimBuffer() {
        guard !isSyncingFromVim else { return }
        // Don't sync to vim while in insert mode — vim doesn't know about keystrokes.
        // Sync happens when exiting insert mode.
        guard vimBridge?.mode != .insert else { return }
        vimBridge?.syncFromTextView(string)
    }

    /// Pulls the current buffer and cursor/selection from vim into the text view.
    func syncFromVimBuffer() {
        guard let bridge = vimBridge else { return }

        isSyncingFromVim = true
        defer { isSyncingFromVim = false }

        let newText = bridge.getCurrentBuffer()
        if newText != string {
            string = newText
        }

        if let visualRange = bridge.getVisualRange() {
            let startLine = visualRange.start.line
            let endLine = visualRange.end.line

            let startOffset: Int
            let endOffset: Int

            if bridge.mode == .visualLine {
                // V-LINE: select entire lines including content
                let lines = string.components(separatedBy: "\n")
                let minLine = min(startLine, endLine)
                let maxLine = max(startLine, endLine)
                startOffset = offsetForPosition(line: minLine, column: 0)
                if maxLine <= lines.count {
                    endOffset = offsetForPosition(line: maxLine, column: lines[maxLine - 1].count)
                } else {
                    endOffset = string.count
                }
            } else {
                startOffset = offsetForPosition(line: visualRange.start.line, column: visualRange.start.col)
                endOffset = offsetForPosition(line: visualRange.end.line, column: visualRange.end.col + 1)
            }

            let range = NSRange(location: min(startOffset, endOffset), length: abs(endOffset - startOffset))
            setSelectedRange(range)
        } else {
            let (line, col) = bridge.getCursorPosition()
            let cursorOffset = offsetForPosition(line: line, column: col)
            setSelectedRange(NSRange(location: cursorOffset, length: 0))
        }

        updateCursor()
    }

    /// Pushes the NSTextView's cursor position into vim.
    func syncCursorToVim() {
        guard let bridge = vimBridge else { return }
        let cursorLocation = selectedRange().location
        let (line, col) = positionForOffset(cursorLocation)
        bridge.setCursorPosition(line: line, column: col)
    }

    /// Converts a 1-indexed (line, column) to a character offset in the string.
    /// @param line 1-indexed line number.
    /// @param column 0-indexed column within the line.
    /// @returns Character offset clamped to string bounds.
    func offsetForPosition(line: Int, column: Int) -> Int {
        let lines = string.components(separatedBy: "\n")
        var offset = 0

        for i in 0..<min(line - 1, lines.count) {
            offset += lines[i].count + 1 // +1 for newline
        }

        if line >= 1 && line <= lines.count {
            offset += min(column, lines[line - 1].count)
        }

        return min(offset, string.count)
    }

    /// Converts a character offset to a 1-indexed (line, column) position.
    /// @param offset Character offset in the string.
    /// @returns Tuple of (line, column), line is 1-indexed.
    private func positionForOffset(_ offset: Int) -> (line: Int, column: Int) {
        let lines = string.components(separatedBy: "\n")
        var currentOffset = 0

        for (index, lineContent) in lines.enumerated() {
            let lineLength = lineContent.count + 1

            if currentOffset + lineLength > offset {
                return (index + 1, offset - currentOffset)
            }

            currentOffset += lineLength
        }

        return (lines.count, lines.last?.count ?? 0)
    }
}
