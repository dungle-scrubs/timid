import SwiftUI
import AppKit

/// NSViewRepresentable wrapping VimTextView with real-time markdown syntax highlighting.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var vimMode: VimMode
    var vimEnabled: Bool
    var onTextChange: (String) -> Void
    var onEscape: (() -> Void)?
    var onReady: ((VimTextView) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = VimTextView(frame: .zero, textContainer: textContainer)
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator
        textView.vimEnabled = vimEnabled

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let bridge = VimBridge()
        textView.vimBridge = bridge
        context.coordinator.vimBridge = bridge
        context.coordinator.textView = textView

        let coordinator = context.coordinator
        bridge.onModeChange = { mode in
            DispatchQueue.main.async {
                coordinator.parent.vimMode = mode
            }
        }

        bridge.onBufferChange = { newText in
            DispatchQueue.main.async {
                coordinator.parent.text = newText
                coordinator.parent.onTextChange(newText)
            }
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        if !text.isEmpty {
            textView.string = text
            bridge.syncFromTextView(text)
        }

        textView.onEscapeInNormalMode = onEscape

        onReady?(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimTextView else { return }

        // Keep coordinator's parent reference up to date with current struct instance
        context.coordinator.parent = self

        textView.vimEnabled = vimEnabled
        textView.onEscapeInNormalMode = onEscape

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.applyHighlighting(to: textView)
            textView.syncToVimBuffer()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var vimBridge: VimBridge?
        weak var textView: VimTextView?

        // Cache compiled regex patterns — reused on every keystroke
        private static let boldRegex = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
        private static let italicRegex = try? NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#)
        private static let codeRegex = try? NSRegularExpression(pattern: #"`([^`]+)`"#)
        private static let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^\)]+\)"#)

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? VimTextView else { return }
            parent.text = textView.string
            parent.onTextChange(textView.string)
            applyHighlighting(to: textView)
            textView.syncToVimBuffer()
        }

        /// Applies markdown syntax highlighting to the text view's attributed string.
        /// Handles headings (H1-H3), bold, italic, inline code, and links.
        func applyHighlighting(to textView: NSTextView) {
            let text = textView.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            guard let textStorage = textView.textStorage else { return }

            textStorage.beginEditing()

            textStorage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: fullRange)

            let lines = text.components(separatedBy: "\n")
            var location = 0

            for line in lines {
                let lineLength = (line as NSString).length
                let lineRange = NSRange(location: location, length: lineLength)

                if line.hasPrefix("# ") {
                    textStorage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                        .foregroundColor: NSColor.labelColor
                    ], range: lineRange)
                } else if line.hasPrefix("## ") {
                    textStorage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                        .foregroundColor: NSColor.labelColor
                    ], range: lineRange)
                } else if line.hasPrefix("### ") {
                    textStorage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
                        .foregroundColor: NSColor.labelColor
                    ], range: lineRange)
                }

                location += lineLength + 1
            }

            // Inline patterns using cached regex
            if let regex = Self.boldRegex {
                applyPattern(regex, to: textStorage, in: text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
                ])
            }

            if let regex = Self.italicRegex {
                let italicFont = NSFont(
                    descriptor: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                        .fontDescriptor.withSymbolicTraits(.italic),
                    size: 14
                ) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                applyPattern(regex, to: textStorage, in: text, attributes: [.font: italicFont])
            }

            if let regex = Self.codeRegex {
                applyPattern(regex, to: textStorage, in: text, attributes: [
                    .foregroundColor: NSColor.systemPink,
                    .backgroundColor: NSColor.quaternaryLabelColor
                ])
            }

            if let regex = Self.linkRegex {
                applyPattern(regex, to: textStorage, in: text, attributes: [
                    .foregroundColor: NSColor.systemBlue
                ])
            }

            textStorage.endEditing()
        }

        /// @param regex Pre-compiled regex pattern to match.
        /// @param textStorage The text storage to apply attributes to.
        /// @param text The plain text to search.
        /// @param attributes Attributes to apply to each match.
        private func applyPattern(_ regex: NSRegularExpression, to textStorage: NSTextStorage, in text: String, attributes: [NSAttributedString.Key: Any]) {
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            for match in regex.matches(in: text, range: fullRange) {
                textStorage.addAttributes(attributes, range: match.range)
            }
        }
    }
}

/// Compact vim mode badge shown at the bottom-left of the editor.
struct VimModeIndicator: View {
    let mode: VimMode

    private var backgroundColor: Color {
        switch mode {
        case .normal: return .blue
        case .insert: return .green
        case .visual, .visualLine, .visualBlock: return .purple
        case .command: return .orange
        case .replace: return .red
        }
    }

    var body: some View {
        Text(mode.rawValue)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .cornerRadius(3)
    }
}
