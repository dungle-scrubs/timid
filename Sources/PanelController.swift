import SwiftUI
import AppKit

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Don't close on Escape - use hotkey to toggle
    }

    override func keyDown(with event: NSEvent) {
        // Let the text view handle all keys including Escape
        super.keyDown(with: event)
    }
}

class PanelController {
    private var panel: NSPanel?
    private var isVisible = false
    private let notesDirectory: URL
    private var hostingView: NSHostingView<PanelContentView>?
    private var previousApp: NSRunningApplication?

    init() {
        // Default to ~/Documents/ObsidianVault/stickies - user can change this
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.notesDirectory = home.appendingPathComponent("obsidian/stickies")

        setupPanel()
    }

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelWidth = screenFrame.width * 0.4
        let panelHeight = screenFrame.height

        // Start offscreen to the right
        let offscreenFrame = NSRect(
            x: screenFrame.maxX,
            y: screenFrame.minY,
            width: panelWidth,
            height: panelHeight
        )

        let keyablePanel = KeyablePanel(
            contentRect: offscreenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel = keyablePanel

        guard let panel = panel else { return }

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let contentView = PanelContentView(
            notesDirectory: notesDirectory,
            onClose: { [weak self] in self?.hide() },
            onResize: { [weak self] width in self?.resize(toWidth: width) },
            getScreenMaxX: { NSScreen.main?.visibleFrame.maxX ?? 0 }
        )
        let hosting = NSHostingView(rootView: contentView)
        hostingView = hosting
        panel.contentView = hostingView
    }

    private func resize(toWidth width: CGFloat) {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let minWidth: CGFloat = 300
        let maxWidth = screenFrame.width * 0.8

        let newWidth = max(minWidth, min(maxWidth, width))
        let newFrame = NSRect(
            x: screenFrame.maxX - newWidth,
            y: screenFrame.minY,
            width: newWidth,
            height: screenFrame.height
        )
        panel.setFrame(newFrame, display: true)
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let panel = panel, let screen = NSScreen.main else { return }

        // Store the currently active app to restore later
        previousApp = NSWorkspace.shared.frontmostApplication

        let screenFrame = screen.visibleFrame
        let panelWidth = panel.frame.width

        // Position offscreen first
        let offscreenFrame = NSRect(
            x: screenFrame.maxX,
            y: screenFrame.minY,
            width: panelWidth,
            height: screenFrame.height
        )
        panel.setFrame(offscreenFrame, display: false)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Animate to visible position
        let visibleFrame = NSRect(
            x: screenFrame.maxX - panelWidth,
            y: screenFrame.minY,
            width: panelWidth,
            height: screenFrame.height
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            // Custom cubic-bezier: fast start, gentle deceleration with slight overshoot feel
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(visibleFrame, display: true)
        }

        isVisible = true
    }

    func hide() {
        guard let panel = panel, let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelWidth = panel.frame.width

        let offscreenFrame = NSRect(
            x: screenFrame.maxX,
            y: screenFrame.minY,
            width: panelWidth,
            height: screenFrame.height
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(offscreenFrame, display: true)
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.isVisible = false
            self?.previousApp?.activate()
            self?.previousApp = nil
        })
    }
}

struct PanelContentView: View {
    let notesDirectory: URL
    let onClose: () -> Void
    let onResize: (CGFloat) -> Void
    let getScreenMaxX: () -> CGFloat

    @State private var currentNote: NoteFile?
    @State private var notes: [NoteFile] = []
    @State private var editedContent: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var vimMode: VimMode = .normal
    @State private var vimEnabled: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            // Resize handle
            ResizeHandle(onResize: onResize, getScreenMaxX: getScreenMaxX)

            VStack(spacing: 0) {
            // Header
            HStack {
                if let note = currentNote {
                    Text(note.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                } else {
                    Text("Timid")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if notes.count > 1 {
                    Text("\(currentNoteIndex + 1) / \(notes.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Content
            if currentNote != nil {
                ZStack(alignment: .bottomLeading) {
                    MarkdownEditor(
                        text: $editedContent,
                        vimMode: $vimMode,
                        vimEnabled: vimEnabled,
                        onTextChange: { newValue in
                            scheduleAutoSave(content: newValue)
                        },
                        onEscape: onClose
                    )

                    // Vim mode indicator
                    if vimEnabled {
                        VimModeIndicator(mode: vimMode)
                            .padding(8)
                    }
                }
            } else {
                VStack {
                    Spacer()
                    Text("No notes found")
                        .foregroundColor(.secondary)
                    Text(notesDirectory.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            // Navigation
            if notes.count > 1 {
                Divider()
                HStack {
                    Button(action: previousNote) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentNoteIndex == 0)

                    Spacer()

                    Button(action: nextNote) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(currentNoteIndex == notes.count - 1)
                }
                .padding()
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(LeftRoundedRectangle(radius: 12))
        .onAppear(perform: loadNotes)
    }

    private func scheduleAutoSave(content: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
            guard !Task.isCancelled, let note = currentNote else { return }
            try? content.write(to: note.url, atomically: true, encoding: .utf8)
        }
    }

    private var currentNoteIndex: Int {
        guard let note = currentNote else { return 0 }
        return notes.firstIndex(where: { $0.url == note.url }) ?? 0
    }

    private func loadNotes() {
        vimLog("[loadNotes] called")
        let fm = FileManager.default

        // Create directory if it doesn't exist
        if !fm.fileExists(atPath: notesDirectory.path) {
            vimLog("[loadNotes] creating directory: \(notesDirectory.path)")
            try? fm.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        }

        guard let files = try? fm.contentsOfDirectory(at: notesDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            vimLog("[loadNotes] failed to read directory")
            return
        }

        vimLog("[loadNotes] found \(files.count) files")
        notes = files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> NoteFile? in
                guard let content = try? String(contentsOf: url, encoding: .utf8),
                      let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let modDate = attrs[.modificationDate] as? Date else {
                    vimLog("[loadNotes] failed to load: \(url.lastPathComponent)")
                    return nil
                }
                return NoteFile(url: url, content: content, modifiedAt: modDate)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }

        vimLog("[loadNotes] loaded \(notes.count) notes")
        if let first = notes.first {
            currentNote = first
            editedContent = first.content
            vimLog("[loadNotes] set editedContent, count=\(first.content.count)")
        } else {
            vimLog("[loadNotes] no notes found")
        }
    }

    private func previousNote() {
        let index = currentNoteIndex
        if index > 0 {
            let note = notes[index - 1]
            currentNote = note
            editedContent = note.content
        }
    }

    private func nextNote() {
        let index = currentNoteIndex
        if index < notes.count - 1 {
            let note = notes[index + 1]
            currentNote = note
            editedContent = note.content
        }
    }
}

struct NoteFile: Identifiable {
    let id = UUID()
    let url: URL
    let content: String
    let modifiedAt: Date

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }
}

struct LeftRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(180),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct ResizeHandle: View {
    let onResize: (CGFloat) -> Void
    let getScreenMaxX: () -> CGFloat

    var body: some View {
        ZStack {
            ResizeHandleView(onResize: onResize, getScreenMaxX: getScreenMaxX)
                .frame(maxHeight: .infinity)

            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 4, height: 1)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
    }
}

struct ResizeHandleView: NSViewRepresentable {
    let onResize: (CGFloat) -> Void
    let getScreenMaxX: () -> CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = ResizeDragView()
        view.onResize = onResize
        view.getScreenMaxX = getScreenMaxX
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class ResizeDragView: NSView {
    var onResize: ((CGFloat) -> Void)?
    var getScreenMaxX: (() -> CGFloat)?
    private var cursorToEdgeOffset: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var isDragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.push()
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            NSCursor.pop()
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        let cursorX = NSEvent.mouseLocation.x
        let panelLeftEdge = window?.frame.minX ?? 0
        cursorToEdgeOffset = cursorX - panelLeftEdge
    }

    override func mouseDragged(with event: NSEvent) {
        let cursorX = NSEvent.mouseLocation.x
        let targetLeftEdge = cursorX - cursorToEdgeOffset
        let screenMaxX = getScreenMaxX?() ?? 0
        let newWidth = screenMaxX - targetLeftEdge
        onResize?(newWidth)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        NSCursor.pop()
    }
}
