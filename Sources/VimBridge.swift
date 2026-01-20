import AppKit
import libvim

func vimLog(_ message: String) {
    let fm = FileManager.default
    let logsDir = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Logs")
        .appendingPathComponent("Timid")
    let logURL = logsDir.appendingPathComponent("debug.log")

    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let entry = "[\(timestamp)] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        if let data = entry.data(using: .utf8) {
            handle.write(data)
        }
        try? handle.close()
    } else {
        _ = fm.createFile(atPath: logURL.path, contents: entry.data(using: .utf8))
    }
}

enum VimMode: String {
    case normal = "NORMAL"
    case insert = "INSERT"
    case visual = "VISUAL"
    case visualLine = "V-LINE"
    case visualBlock = "V-BLOCK"
    case command = "COMMAND"
    case replace = "REPLACE"
}

final class VimBridge {
    var mode: VimMode = .normal
    var onModeChange: ((VimMode) -> Void)?
    var onBufferChange: ((String) -> Void)?
    var onCursorChange: ((Int, Int) -> Void)? // line, column (1-indexed)

    private var isInitialized = false
    private var lastKnownText = ""

    init() {
        vimLog("[VimBridge.init] Starting initialization...")
        vimInit()
        vimLog("[VimBridge.init] vimInit() completed")
        isInitialized = true

        let buf = vimBufferGetCurrent()
        let initialLineCount = vimBufferGetLineCount(buf)
        vimLog("[VimBridge.init] initial buffer lineCount: \(initialLineCount)")

        vimSetBufferUpdateCallback { [weak self] _ in
            self?.syncBufferToCallback()
        }
        vimLog("[VimBridge.init] Initialization complete")
    }

    func syncFromTextView(_ text: String) {
        vimLog("[syncFromTextView] called with text: '\(text.prefix(50))...', lastKnownText: '\(lastKnownText.prefix(50))...'")
        guard isInitialized else {
            vimLog("[syncFromTextView] not initialized, skipping")
            return
        }
        guard text != lastKnownText else {
            vimLog("[syncFromTextView] text == lastKnownText, skipping")
            return
        }
        lastKnownText = text

        let buf = vimBufferGetCurrent()
        let lines = text.components(separatedBy: "\n")
        let lineCount = vimBufferGetLineCount(buf)

        vimLog("[syncFromTextView] buf=\(buf), setting \(lines.count) lines, old lineCount: \(lineCount)")

        // Clear buffer first by deleting all lines
        if lineCount > 0 {
            vimLog("[syncFromTextView] deleting existing lines")
            vimBufferSetLines(buf, 0, lineCount, [], 0)
        }

        // Insert new lines
        vimLog("[syncFromTextView] inserting new lines")
        vimBufferSetLines(buf, 0, 0, lines, lines.count)

        let newLineCount = vimBufferGetLineCount(buf)
        vimLog("[syncFromTextView] after set, lineCount: \(newLineCount)")
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard isInitialized else {
            vimLog("[VimBridge] Not initialized!")
            return false
        }

        let oldMode = mode
        var handled = false

        if let special = specialKeyString(for: event) {
            vimLog("[VimBridge] Sending special key: \(special)")
            vimKey(special)
            handled = true
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            let modifiers = event.modifierFlags

            if modifiers.contains(.control), let char = chars.first {
                let ctrlKey = "<C-\(char)>"
                vimLog("[VimBridge] Sending ctrl key: \(ctrlKey)")
                vimKey(ctrlKey)
                handled = true
            } else if modifiers.contains(.option), let char = chars.first {
                let altKey = "<M-\(char)>"
                vimLog("[VimBridge] Sending alt key: \(altKey)")
                vimKey(altKey)
                handled = true
            } else {
                vimLog("[VimBridge] Sending chars: \(chars)")
                for char in chars {
                    vimInput(String(char))
                }
                handled = true
            }
        }

        updateMode()
        vimLog("[VimBridge] Mode after: \(mode), cursor: (\(vimCursorGetLine()), \(vimCursorGetColumn()))")

        if mode != oldMode {
            vimLog("[VimBridge] Mode changed: \(oldMode) -> \(mode)")
            onModeChange?(mode)
        }

        onCursorChange?(Int(vimCursorGetLine()), Int(vimCursorGetColumn()))

        return handled
    }

    func getCurrentBuffer() -> String {
        let buf = vimBufferGetCurrent()
        let lineCount = vimBufferGetLineCount(buf)
        vimLog("[getCurrentBuffer] buf=\(buf), lineCount=\(lineCount)")
        var lines: [String] = []

        for i in 1...max(1, lineCount) {
            let line = vimBufferGetLine(buf, i)
            vimLog("[getCurrentBuffer] line \(i): '\(line)'")
            lines.append(line)
        }

        let result = lines.joined(separator: "\n")
        vimLog("[getCurrentBuffer] result: '\(result.prefix(50))...'")
        return result
    }

    func getCursorPosition() -> (line: Int, column: Int) {
        (Int(vimCursorGetLine()), Int(vimCursorGetColumn()))
    }

    func getVisualRange() -> (start: (line: Int, col: Int), end: (line: Int, col: Int))? {
        guard vimVisualIsActive() else { return nil }
        let (start, end) = vimVisualGetRange()
        return (
            start: (line: start.lnum, col: Int(start.col)),
            end: (line: end.lnum, col: Int(end.col))
        )
    }

    func isVisualActive() -> Bool {
        vimVisualIsActive()
    }

    func setCursorPosition(line: Int, column: Int) {
        var pos = Vim.Position()
        pos.lnum = Int(line)
        pos.col = Int32(column)
        vimCursorSetPosition(pos)
    }

    private func updateMode() {
        let state = vimGetMode()

        if state.contains(.insert) {
            if state.contains(.replaceFlag) {
                mode = .replace
            } else {
                mode = .insert
            }
        } else if state.contains(.visual) || state.contains(.selectMode) {
            let visualType = vimVisualGetType()
            switch visualType {
            case "V":
                mode = .visualLine
            case "\u{16}": // Ctrl-V
                mode = .visualBlock
            default:
                mode = .visual
            }
        } else if state.contains(.cmdLine) {
            mode = .command
        } else {
            mode = .normal
        }
    }

    private func syncBufferToCallback() {
        let newText = getCurrentBuffer()
        if newText != lastKnownText {
            lastKnownText = newText
            onBufferChange?(newText)
        }
    }

    private func specialKeyString(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 53: return "<Esc>"
        case 36: return "<CR>"
        case 48: return "<Tab>"
        case 51: return "<BS>"
        case 117: return "<Del>"
        case 123: return "<Left>"
        case 124: return "<Right>"
        case 125: return "<Down>"
        case 126: return "<Up>"
        case 115: return "<Home>"
        case 119: return "<End>"
        case 116: return "<PageUp>"
        case 121: return "<PageDown>"
        default: return nil
        }
    }
}
