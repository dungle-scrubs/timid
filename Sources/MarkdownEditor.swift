import SwiftUI
import AppKit

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var vimMode: VimMode
    var vimEnabled: Bool
    var onTextChange: (String) -> Void
    var onEscape: (() -> Void)?
    var onReady: ((VimTextView) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        vimLog("[makeNSView] called, text.count=\(text.count)")
        // Create text container and layout manager properly
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

        // Setup vim bridge
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

        // Initial sync - load current text into vim
        if !text.isEmpty {
            textView.string = text
            bridge.syncFromTextView(text)
        }

        // Wire up escape in normal mode to close
        textView.onEscapeInNormalMode = onEscape

        onReady?(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        vimLog("[updateNSView] called, text.count=\(text.count)")
        guard let textView = scrollView.documentView as? VimTextView else {
            vimLog("[updateNSView] guard failed - no VimTextView")
            return
        }

        // Keep coordinator's parent reference up to date with current struct instance
        context.coordinator.parent = self

        textView.vimEnabled = vimEnabled
        textView.onEscapeInNormalMode = onEscape

        if textView.string != text {
            vimLog("[updateNSView] textView.string != text")
            vimLog("[updateNSView] textView: '\(textView.string.prefix(50))...'")
            vimLog("[updateNSView] text binding: '\(text.prefix(50))...'")
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

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            vimLog("[textDidChange] fired, object type: \(type(of: notification.object))")
            guard let textView = notification.object as? VimTextView else {
                vimLog("[textDidChange] guard failed - not VimTextView")
                return
            }
            vimLog("[textDidChange] setting parent.text to: '\(textView.string.prefix(50))...'")
            parent.text = textView.string
            parent.onTextChange(textView.string)
            applyHighlighting(to: textView)
            textView.syncToVimBuffer()
        }

        func applyHighlighting(to textView: NSTextView) {
            let text = textView.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            guard let textStorage = textView.textStorage else { return }

            textStorage.beginEditing()

            // Reset to default
            textStorage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: fullRange)

            let lines = text.components(separatedBy: "\n")
            var location = 0

            for line in lines {
                let lineLength = (line as NSString).length
                let lineRange = NSRange(location: location, length: lineLength)

                // H1 - # heading
                if line.hasPrefix("# ") {
                    textStorage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                        .foregroundColor: NSColor.labelColor
                    ], range: lineRange)
                }
                // H2 - ## heading
                else if line.hasPrefix("## ") {
                    textStorage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                        .foregroundColor: NSColor.labelColor
                    ], range: lineRange)
                }
                // H3 - ### heading
                else if line.hasPrefix("### ") {
                    textStorage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
                        .foregroundColor: NSColor.labelColor
                    ], range: lineRange)
                }

                location += lineLength + 1 // +1 for newline
            }

            // Inline patterns
            applyPattern(#"\*\*(.+?)\*\*"#, to: textStorage, in: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
            ])

            applyPattern(#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, to: textStorage, in: text, attributes: [
                .font: NSFont(descriptor: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontDescriptor.withSymbolicTraits(.italic), size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            ])

            applyPattern(#"`([^`]+)`"#, to: textStorage, in: text, attributes: [
                .foregroundColor: NSColor.systemPink,
                .backgroundColor: NSColor.quaternaryLabelColor
            ])

            applyPattern(#"\[([^\]]+)\]\([^\)]+\)"#, to: textStorage, in: text, attributes: [
                .foregroundColor: NSColor.systemBlue
            ])

            textStorage.endEditing()
        }

        private func applyPattern(_ pattern: String, to textStorage: NSTextStorage, in text: String, attributes: [NSAttributedString.Key: Any]) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            let matches = regex.matches(in: text, options: [], range: fullRange)

            for match in matches {
                textStorage.addAttributes(attributes, range: match.range)
            }
        }
    }
}

struct VimModeIndicator: View {
    let mode: VimMode

    private var backgroundColor: Color {
        switch mode {
        case .normal:
            return .blue
        case .insert:
            return .green
        case .visual, .visualLine, .visualBlock:
            return .purple
        case .command:
            return .orange
        case .replace:
            return .red
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
