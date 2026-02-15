import SwiftUI
import AppKit

/// Main content view inside the slide-out panel.
/// Contains the header, search overlay, markdown editor, and note navigation.
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
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ResizeHandle(onResize: onResize, getScreenMaxX: getScreenMaxX)

            VStack(spacing: 0) {
                if panelState.isSearchVisible {
                    searchHeader
                } else {
                    noteHeader
                }

                Divider()

                if panelState.isSearchVisible {
                    searchResults
                } else if currentNote != nil {
                    editorArea
                } else {
                    emptyState
                }

                if !panelState.isSearchVisible && notes.count > 1 {
                    Divider()
                    navigationBar
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
                panelState.searchQuery = ""
                panelState.selectedIndex = 0
                isSearchFieldFocused = true
            } else {
                isSearchFieldFocused = false
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
        .onChange(of: isSearchFieldFocused) { isFocused in
            panelState.isSearchFieldFocused = isFocused
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window == editorView?.window,
                  !panelState.isSearchVisible else { return }
            focusEditor()
        }
    }

    // MARK: - Subviews

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search notes (⌘P)", text: $panelState.searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
                .onSubmit { openSelectedSearchResult() }
            Button("Cancel") { panelState.closeSearch() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { panelState.closeSearch() }
        .onAppear {
            DispatchQueue.main.async { isSearchFieldFocused = true }
        }
    }

    private var noteHeader: some View {
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

    private var searchResults: some View {
        SearchResultsList(
            results: filteredNotes,
            selectedIndex: panelState.selectedIndex,
            onSelect: { note in
                openNote(note)
                panelState.closeSearch()
            },
            onSelectIndex: { index in
                panelState.selectedIndex = index
            }
        )
        .onMoveCommand { direction in
            switch direction {
            case .up: panelState.moveSelection(delta: -1)
            case .down: panelState.moveSelection(delta: 1)
            default: break
            }
        }
    }

    private var editorArea: some View {
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

            if vimEnabled {
                VimModeIndicator(mode: vimMode)
                    .padding(8)
            }
        }
    }

    private var emptyState: some View {
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

    private var navigationBar: some View {
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

    // MARK: - Auto-save

    /// Debounces saves with a 500ms delay. Logs errors instead of silently swallowing them.
    /// @param content The text content to write to disk.
    private func scheduleAutoSave(content: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let note = currentNote else { return }
            do {
                try content.write(to: note.url, atomically: true, encoding: .utf8)
            } catch {
                vimLog("[autoSave] ERROR: failed to save \(note.relativePath): \(error)")
            }
        }
    }

    // MARK: - Note management

    private var currentNoteIndex: Int {
        guard let note = currentNote else { return 0 }
        return notes.firstIndex(where: { $0.url == note.url }) ?? 0
    }

    /// Scans the notes directory for markdown files.
    /// Only loads content for the most recent note; others are loaded on-demand.
    private func loadNotes() {
        let fm = FileManager.default

        if !fm.fileExists(atPath: notesDirectory.path) {
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
            guard url.pathExtension == "md" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory != true,
                  let modDate = values.contentModificationDate else { continue }
            let relativePath = url.path.replacingOccurrences(of: notesDirectory.path + "/", with: "")
            found.append(NoteFile(url: url, modifiedAt: modDate, relativePath: relativePath))
        }

        notes = found.sorted { $0.modifiedAt > $1.modifiedAt }
        vimLog("[loadNotes] loaded \(notes.count) notes")

        if let first = notes.first {
            openNote(first)
        }
    }

    private func previousNote() {
        let index = currentNoteIndex
        if index > 0 { openNote(notes[index - 1]) }
    }

    private func nextNote() {
        let index = currentNoteIndex
        if index < notes.count - 1 { openNote(notes[index + 1]) }
    }

    /// @returns Notes filtered by the current search query using fuzzy matching.
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

    /// Scores a fuzzy match with bonuses for consecutive character matches.
    /// @param query Lowercase search string.
    /// @param candidate Lowercase candidate string.
    /// @returns Match score, or nil if the query doesn't match.
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

    /// Loads a note's content from disk and sets it as the current note.
    /// @param note The note to open.
    private func openNote(_ note: NoteFile) {
        vimLog("[openNote] \(note.relativePath)")
        currentNote = note
        do {
            editedContent = try note.loadContent()
        } catch {
            vimLog("[openNote] ERROR: failed to load \(note.relativePath): \(error)")
            editedContent = ""
        }
        focusEditor()
    }

    private func openSelectedSearchResult() {
        let index = panelState.selectedIndex
        guard index >= 0, index < filteredNotes.count else { return }
        let note = filteredNotes[index]
        openNote(note)
        panelState.closeSearch()
    }

    /// Focuses the VimTextView as first responder. Retries up to 3 times
    /// if the editor isn't in a window yet (happens during view setup).
    private func focusEditor() {
        onFocusPanel()
        guard let editorView = editorView else { return }

        func attempt(remaining: Int) {
            guard remaining > 0 else { return }
            NSApp.activate(ignoringOtherApps: true)
            guard let window = editorView.window else {
                // View not yet in window hierarchy — retry after a brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    attempt(remaining: remaining - 1)
                }
                return
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editorView)
        }

        DispatchQueue.main.async {
            attempt(remaining: 3)
        }
    }
}
