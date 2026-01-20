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

class PanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var isVisible = false
    private var notesDirectory: URL
    private var hostingView: NSHostingView<PanelContentView>?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private let panelState = PanelState()
    private var lastGPressTime: TimeInterval = 0

    override init() {
        // Default to ~/obsidian - user can change this
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.notesDirectory = home.appendingPathComponent("obsidian")
        super.init()
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

        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let contentView = PanelContentView(
            notesDirectory: notesDirectory,
            panelState: panelState,
            onFocusPanel: { [weak self] in self?.focusPanel() },
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

        installKeyMonitor()
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
            self?.removeKeyMonitor()
            self?.previousApp?.activate()
            self?.previousApp = nil
        })
    }

    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "p" {
                self.panelState.toggleSearch()
                return nil
            }
            if event.keyCode == 53, self.panelState.isSearchVisible {
                self.panelState.closeSearch()
                return nil
            }
            if self.panelState.isSearchVisible {
                if event.keyCode == 126 { // up arrow
                    self.panelState.moveSelection(delta: -1)
                    return nil
                }
                if event.keyCode == 125 { // down arrow
                    self.panelState.moveSelection(delta: 1)
                    return nil
                }
                if !self.panelState.isSearchFieldFocused {
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if event.keyCode == 5, modifiers.contains(.shift) { // G
                        self.panelState.selectLast()
                        return nil
                    }
                    if event.keyCode == 5, modifiers.isDisjoint(with: [.command, .control, .option, .shift]) { // g
                        let now = Date().timeIntervalSinceReferenceDate
                        if now - self.lastGPressTime < 0.4 {
                            self.panelState.selectFirst()
                            self.lastGPressTime = 0
                            return nil
                        } else {
                            self.lastGPressTime = now
                        }
                    }
                }
            }
            if !self.panelState.isSearchVisible {
                let responderName = self.panel?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                if !(self.panel?.firstResponder is VimTextView) {
                    vimLog("[keyMonitor] key=\(event.keyCode) responder=\(responderName) isKey=\(self.panel?.isKeyWindow == true)")
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func focusPanel() {
        guard let panel = panel else { return }
        vimLog("[focusPanel] called, isKey=\(panel.isKeyWindow), isMain=\(panel.isMainWindow)")
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
        panel.makeMain()
        vimLog("[focusPanel] after, isKey=\(panel.isKeyWindow), isMain=\(panel.isMainWindow)")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        vimLog("[windowDidBecomeKey] panel isKey=\(panel?.isKeyWindow == true)")
    }

    func windowDidResignKey(_ notification: Notification) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        vimLog("[windowDidResignKey] panel isKey=\(panel?.isKeyWindow == true) frontmost=\(frontmost)")
        guard isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeMain()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        vimLog("[windowDidBecomeMain] panel isMain=\(panel?.isMainWindow == true)")
    }

    func windowDidResignMain(_ notification: Notification) {
        vimLog("[windowDidResignMain] panel isMain=\(panel?.isMainWindow == true)")
    }
}

struct PanelContentView: View {
    let notesDirectory: URL
    @ObservedObject var panelState: PanelState
    let onFocusPanel: () -> Void
    let onClose: () -> Void
    let onResize: (CGFloat) -> Void
    let getScreenMaxX: () -> CGFloat

    @State private var currentNote: NoteFile?
    @State private var notes: [NoteFile] = []
    @State private var editedContent: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var vimMode: VimMode = .normal
    @State private var vimEnabled: Bool = true
    @State private var editorView: VimTextView?

    var body: some View {
        HStack(spacing: 0) {
            // Resize handle
            ResizeHandle(onResize: onResize, getScreenMaxX: getScreenMaxX)

            VStack(spacing: 0) {
            // Header / Search
            if panelState.isSearchVisible {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    SearchFieldView(
                        text: $panelState.searchQuery,
                        isFirstResponder: $panelState.isSearchFieldFocused,
                        placeholder: "Search notes (⌘P)",
                        onSubmit: { openFirstSearchResult() }
                    )
                    Button("Cancel") { panelState.closeSearch() }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))
                .onExitCommand { panelState.closeSearch() }
                .onAppear {
                    DispatchQueue.main.async {
                        panelState.isSearchFieldFocused = true
                    }
                }
            } else {
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
            }

            Divider()

            // Content
            if panelState.isSearchVisible {
                SearchResultsList(
                    results: filteredNotes,
                    selectedIndex: panelState.selectedIndex,
                    onSelect: { note in
                        openNote(note)
                        panelState.closeSearch()
                    }
                    ,
                    onSelectIndex: { index in
                        panelState.selectedIndex = index
                    }
                )
                .onMoveCommand { direction in
                    switch direction {
                    case .up:
                        panelState.moveSelection(delta: -1)
                    case .down:
                        panelState.moveSelection(delta: 1)
                    default:
                        break
                    }
                }
            } else if currentNote != nil {
                ZStack(alignment: .bottomLeading) {
                    MarkdownEditor(
                        text: $editedContent,
                        vimMode: $vimMode,
                        vimEnabled: vimEnabled,
                        onTextChange: { newValue in
                            scheduleAutoSave(content: newValue)
                        },
                        onEscape: onClose,
                        onReady: { view in
                            editorView = view
                            if !panelState.isSearchVisible {
                                focusEditor()
                            }
                        }
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
            if !panelState.isSearchVisible && notes.count > 1 {
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
        .onChange(of: panelState.searchQuery) { _ in
            panelState.resetSelection()
        }
        .onChange(of: filteredNotes.count) { count in
            panelState.searchResultCount = count
            panelState.clampSelection()
        }
        .onChange(of: panelState.isSearchVisible) { isVisible in
            if isVisible {
                panelState.isSearchFieldFocused = true
            } else {
                focusEditor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusEditor()
                }
            }
        }
        .onChange(of: currentNote?.url) { _ in
            if !panelState.isSearchVisible {
                focusEditor()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow else { return }
            guard window == editorView?.window else { return }
            vimLog("[windowDidBecomeKey] focus editor in content view")
            if !panelState.isSearchVisible {
                focusEditor()
            }
        }
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

        guard let enumerator = fm.enumerator(
            at: notesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            vimLog("[loadNotes] failed to read directory")
            return
        }

        var found: [NoteFile] = []
        for case let url as URL in enumerator {
            if url.pathExtension != "md" { continue }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory != true,
                  let modDate = values.contentModificationDate else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                vimLog("[loadNotes] failed to load: \(url.lastPathComponent)")
                continue
            }
            let relativePath = url.path.replacingOccurrences(of: notesDirectory.path + "/", with: "")
            found.append(NoteFile(url: url, content: content, modifiedAt: modDate, relativePath: relativePath))
        }

        vimLog("[loadNotes] found \(found.count) files")
        notes = found.sorted { $0.modifiedAt > $1.modifiedAt }

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
            openNote(note)
        }
    }

    private func nextNote() {
        let index = currentNoteIndex
        if index < notes.count - 1 {
            let note = notes[index + 1]
            openNote(note)
        }
    }

    private var filteredNotes: [NoteFile] {
        let query = panelState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return notes }
        let lowerQuery = query.lowercased()
        return notes
            .compactMap { note -> (NoteFile, Int)? in
                guard let score = fuzzyScore(query: lowerQuery, candidate: note.searchableName) else { return nil }
                return (note, score)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    private func fuzzyScore(query: String, candidate: String) -> Int? {
        var score = 0
        var lastMatchIndex = -1
        var queryIndex = query.startIndex
        let candidateChars = Array(candidate)

        for (i, char) in candidateChars.enumerated() {
            if queryIndex == query.endIndex { break }
            if char == query[queryIndex] {
                let consecutiveBonus = (i == lastMatchIndex + 1) ? 5 : 0
                score += 10 + consecutiveBonus
                lastMatchIndex = i
                queryIndex = query.index(after: queryIndex)
            }
        }

        return queryIndex == query.endIndex ? score : nil
    }

    private func openNote(_ note: NoteFile) {
        vimLog("[openNote] \(note.relativePath)")
        currentNote = note
        editedContent = note.content
        focusEditor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let responder = editorView?.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let isKey = editorView?.window?.isKeyWindow == true
            vimLog("[openNote] after-delay isKey=\(isKey) responder=\(responder)")
        }
    }

    private func openFirstSearchResult() {
        let index = panelState.selectedIndex
        guard index >= 0, index < filteredNotes.count else { return }
        let note = filteredNotes[index]
        vimLog("[openFirstSearchResult] index=\(index) name=\(note.relativePath)")
        openNote(note)
        panelState.closeSearch()
    }

    private func focusEditor() {
        onFocusPanel()
        guard let editorView = editorView else {
            vimLog("[focusEditor] skipped, editorView nil")
            return
        }

        func attemptFocus(_ remaining: Int) {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                editorView.window?.makeKeyAndOrderFront(nil)
                if editorView.window != nil {
                    editorView.window?.makeFirstResponder(editorView)
                    let isKey = editorView.window?.isKeyWindow == true
                    let responder = editorView.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    vimLog("[focusEditor] attempt remaining=\(remaining) isKey=\(isKey) responder=\(responder)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        let isKeyLater = editorView.window?.isKeyWindow == true
                        let responderLater = editorView.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                        vimLog("[focusEditor] after-delay isKey=\(isKeyLater) responder=\(responderLater)")
                    }
                } else if remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        attemptFocus(remaining - 1)
                    }
                }
            }
        }

        attemptFocus(6)
    }
}

struct NoteFile: Identifiable {
    let id = UUID()
    let url: URL
    let content: String
    let modifiedAt: Date
    let relativePath: String

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }

    var searchableName: String {
        name.lowercased()
    }
}

final class PanelState: ObservableObject {
    @Published var isSearchVisible: Bool = false
    @Published var searchQuery: String = ""
    @Published var selectedIndex: Int = 0
    @Published var searchResultCount: Int = 0
    @Published var isSearchFieldFocused: Bool = false

    func toggleSearch() {
        if isSearchVisible {
            closeSearch()
        } else {
            isSearchVisible = true
            selectedIndex = 0
            isSearchFieldFocused = true
            vimLog("[search] open")
        }
    }

    func closeSearch() {
        isSearchVisible = false
        searchQuery = ""
        selectedIndex = 0
        isSearchFieldFocused = false
        vimLog("[search] close")
    }

    func moveSelection(delta: Int) {
        guard searchResultCount > 0 else {
            selectedIndex = 0
            return
        }
        let maxIndex = max(0, searchResultCount - 1)
        selectedIndex = min(max(0, selectedIndex + delta), maxIndex)
    }

    func resetSelection() {
        selectedIndex = 0
    }

    func clampSelection() {
        let maxIndex = max(0, searchResultCount - 1)
        selectedIndex = min(max(0, selectedIndex), maxIndex)
    }

    func selectFirst() {
        selectedIndex = 0
    }

    func selectLast() {
        guard searchResultCount > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = max(0, searchResultCount - 1)
    }
}

struct SearchResultsList: View {
    let results: [NoteFile]
    let selectedIndex: Int
    let onSelect: (NoteFile) -> Void
    let onSelectIndex: (Int) -> Void

    var body: some View {
        if results.isEmpty {
            VStack {
                Spacer()
                Text("No matches")
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, note in
                        Button(action: { onSelect(note) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.name)
                                    .foregroundColor(.primary)
                                Text(note.relativePath)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(selectedIndex == index ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                onSelectIndex(index)
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
    }
}

struct SearchFieldView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFirstResponder: $isFirstResponder, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField(string: text)
        searchField.placeholderString = placeholder
        searchField.isBezeled = false
        searchField.focusRingType = .none
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.onAction(_:))
        searchField.delegate = context.coordinator
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if !context.coordinator.isEditing && nsView.stringValue != text {
            nsView.stringValue = text
        }
        if isFirstResponder {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private var text: Binding<String>
        private var isFirstResponder: Binding<Bool>
        private let onSubmit: () -> Void
        var isEditing: Bool = false

        init(text: Binding<String>, isFirstResponder: Binding<Bool>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.isFirstResponder = isFirstResponder
            self.onSubmit = onSubmit
        }

        @objc func onAction(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFirstResponder.wrappedValue = true
            isEditing = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFirstResponder.wrappedValue = false
            isEditing = false
            if let movement = notification.userInfo?["NSTextMovement"] as? Int,
               movement == NSReturnTextMovement {
                onSubmit()
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField {
                text.wrappedValue = field.stringValue
            }
        }
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
