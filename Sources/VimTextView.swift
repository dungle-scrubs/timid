import AppKit

final class VimTextView: NSTextView {
    var vimBridge: VimBridge?
    var vimEnabled = true

    private var isSyncingFromVim = false
    private var blockCursorRect: NSRect?

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
        // Don't draw default cursor in normal mode
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBlockCursor()
    }

    private func drawBlockCursor() {
        guard let bridge = vimBridge, bridge.mode != .insert else { return }

        let (line, col) = bridge.getCursorPosition()
        let offset = offsetForPosition(line: line, column: col)

        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return }

        let charIndex = min(offset, max(0, string.count - 1))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)

        // Get the line fragment rect for vertical positioning
        var lineFragmentRect = NSRect.zero
        layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true)
        let location = layoutManager.location(forGlyphAt: glyphIndex)
        lineFragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

        // Use monospace character width
        let charWidth: CGFloat = 8.4  // Approximate width for 14pt monospace
        let charHeight = lineFragmentRect.height

        var cursorRect = NSRect(
            x: lineFragmentRect.origin.x + location.x + textContainerInset.width,
            y: lineFragmentRect.origin.y + textContainerInset.height,
            width: charWidth,
            height: charHeight
        )

        // Clamp width to single character
        cursorRect.size.width = min(cursorRect.width, charWidth)

        let cursorColor = NSColor.labelColor.withAlphaComponent(0.3)
        cursorColor.setFill()
        NSBezierPath(rect: cursorRect).fill()

        blockCursorRect = cursorRect
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
            if event.keyCode == 53 { // Escape - exit insert mode
                bridge.syncFromTextView(string)
                _ = bridge.handleKey(event)
                let (line, col) = bridge.getCursorPosition()
                let cursorOffset = offsetForPosition(line: line, column: col)
                setSelectedRange(NSRange(location: cursorOffset, length: 0))
                updateCursor()
                return
            }
            // Let NSTextView handle normal typing in insert mode
            super.keyDown(with: event)
            return
        }

        // In normal mode, Escape does nothing (use hotkey to close)
        if bridge.mode == .normal && event.keyCode == 53 {
            return
        }

        // Sync current text TO vim before processing command
        // This ensures vim has the latest text before operations like delete, yank, etc.
        bridge.syncFromTextView(string)

        // In normal/visual/command modes, vim handles everything
        let handled = bridge.handleKey(event)

        if handled {
            syncFromVimBuffer()
        } else {
            super.keyDown(with: event)
        }
    }

    func syncToVimBuffer() {
        guard !isSyncingFromVim else { return }
        // Don't sync to vim while in insert mode - vim doesn't know about keystrokes
        // Sync happens when exiting insert mode
        guard vimBridge?.mode != .insert else { return }
        vimBridge?.syncFromTextView(string)
    }

    func syncFromVimBuffer() {
        guard let bridge = vimBridge else { return }

        isSyncingFromVim = true
        defer { isSyncingFromVim = false }

        let newText = bridge.getCurrentBuffer()
        if newText != string {
            string = newText
        }

        // Sync selection from vim
        if let visualRange = bridge.getVisualRange() {
            let startLine = visualRange.start.line
            let endLine = visualRange.end.line

            let startOffset: Int
            let endOffset: Int

            if bridge.mode == .visualLine {
                // V-LINE: select entire lines (text content only, including newline)
                let lines = string.components(separatedBy: "\n")
                let minLine = min(startLine, endLine)
                let maxLine = max(startLine, endLine)
                startOffset = offsetForPosition(line: minLine, column: 0)
                // End at the last character of the line + 1 (to include it)
                if maxLine <= lines.count {
                    let lineContent = maxLine <= lines.count ? lines[maxLine - 1] : ""
                    endOffset = offsetForPosition(line: maxLine, column: lineContent.count)
                } else {
                    endOffset = string.count
                }
            } else {
                // Character-wise visual
                startOffset = offsetForPosition(line: visualRange.start.line, column: visualRange.start.col)
                endOffset = offsetForPosition(line: visualRange.end.line, column: visualRange.end.col + 1)
            }

            let range = NSRange(location: min(startOffset, endOffset), length: abs(endOffset - startOffset))
            setSelectedRange(range)
        } else {
            // Normal cursor position
            let (line, col) = bridge.getCursorPosition()
            let cursorOffset = offsetForPosition(line: line, column: col)
            setSelectedRange(NSRange(location: cursorOffset, length: 0))
        }

        updateCursor()
    }

    func syncCursorToVim() {
        guard let bridge = vimBridge else { return }

        let cursorLocation = selectedRange().location
        let (line, col) = positionForOffset(cursorLocation)
        bridge.setCursorPosition(line: line, column: col)
    }

    private func offsetForPosition(line: Int, column: Int) -> Int {
        let lines = string.components(separatedBy: "\n")
        var offset = 0

        for i in 0..<min(line - 1, lines.count) {
            offset += lines[i].count + 1 // +1 for newline
        }

        if line >= 1 && line <= lines.count {
            let lineContent = lines[line - 1]
            offset += min(column, lineContent.count)
        }

        return min(offset, string.count)
    }

    private func positionForOffset(_ offset: Int) -> (line: Int, column: Int) {
        let lines = string.components(separatedBy: "\n")
        var currentOffset = 0
        var line = 1

        for (index, lineContent) in lines.enumerated() {
            let lineLength = lineContent.count + 1 // +1 for newline

            if currentOffset + lineLength > offset {
                let column = offset - currentOffset
                return (index + 1, column)
            }

            currentOffset += lineLength
            line = index + 2
        }

        return (lines.count, lines.last?.count ?? 0)
    }
}
