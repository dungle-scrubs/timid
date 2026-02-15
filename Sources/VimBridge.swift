import AppKit
import libvim

#if DEBUG
private let loggingEnabled = true
#else
private let loggingEnabled = false
#endif

/// Writes a timestamped message to ~/Library/Logs/Timid/debug.log.
/// Only active in DEBUG builds to avoid disk I/O in release.
func vimLog(_ message: String) {
    guard loggingEnabled else { return }

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

/// Wraps libvim to provide a vim state machine for text editing.
/// Manages mode transitions, buffer sync, and cursor positioning.
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

    deinit {
        // Clear callbacks to prevent dangling references
        onModeChange = nil
        onBufferChange = nil
        onCursorChange = nil
        vimSetBufferUpdateCallback(nil)
    }

    /// Syncs text from the NSTextView into the vim buffer.
    /// No-op if text hasn't changed since last sync.
    /// @param text The current text content from the text view.
    func syncFromTextView(_ text: String) {
        guard isInitialized, text != lastKnownText else { return }
        lastKnownText = text

        let buf = vimBufferGetCurrent()
        let lines = text.components(separatedBy: "\n")
        let lineCount = vimBufferGetLineCount(buf)

        if lineCount > 0 {
            vimBufferSetLines(buf, 0, lineCount, [], 0)
        }
        vimBufferSetLines(buf, 0, 0, lines, lines.count)
    }

    /// Processes a key event through vim and updates mode/cursor state.
    /// @param event The NSEvent to translate and send to vim.
    /// @returns true if vim handled the key.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isInitialized else { return false }

        let oldMode = mode
        var handled = false

        if let special = specialKeyString(for: event) {
            vimKey(special)
            handled = true
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            let modifiers = event.modifierFlags

            if modifiers.contains(.control), let char = chars.first {
                vimKey("<C-\(char)>")
                handled = true
            } else if modifiers.contains(.option), let char = chars.first {
                vimKey("<M-\(char)>")
                handled = true
            } else {
                for char in chars {
                    vimInput(String(char))
                }
                handled = true
            }
        }

        updateMode()

        if mode != oldMode {
            vimLog("[VimBridge] Mode changed: \(oldMode) -> \(mode)")
            onModeChange?(mode)
        }

        onCursorChange?(Int(vimCursorGetLine()), Int(vimCursorGetColumn()))
        return handled
    }

    /// @returns The full text content of the current vim buffer.
    func getCurrentBuffer() -> String {
        let buf = vimBufferGetCurrent()
        let lineCount = vimBufferGetLineCount(buf)
        var lines: [String] = []

        for i in 1...max(1, lineCount) {
            lines.append(vimBufferGetLine(buf, i))
        }

        return lines.joined(separator: "\n")
    }

    /// @returns Tuple of (line, column), both 1-indexed.
    func getCursorPosition() -> (line: Int, column: Int) {
        (Int(vimCursorGetLine()), Int(vimCursorGetColumn()))
    }

    /// @returns Visual selection range if visual mode is active, nil otherwise.
    func getVisualRange() -> (start: (line: Int, col: Int), end: (line: Int, col: Int))? {
        guard vimVisualIsActive() else { return nil }
        let (start, end) = vimVisualGetRange()
        return (
            start: (line: start.lnum, col: Int(start.col)),
            end: (line: end.lnum, col: Int(end.col))
        )
    }

    /// @returns Whether visual mode is currently active.
    func isVisualActive() -> Bool {
        vimVisualIsActive()
    }

    /// Sets the vim cursor to the specified position.
    /// @param line 1-indexed line number.
    /// @param column 0-indexed column number.
    func setCursorPosition(line: Int, column: Int) {
        var pos = Vim.Position()
        pos.lnum = Int(line)
        pos.col = Int32(column)
        vimCursorSetPosition(pos)
    }

    private func updateMode() {
        let state = vimGetMode()

        if state.contains(.insert) {
            mode = state.contains(.replaceFlag) ? .replace : .insert
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

    /// @param event The key event to translate.
    /// @returns Vim-format special key string (e.g. "<Esc>", "<CR>"), or nil for regular keys.
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
