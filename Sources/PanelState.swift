import Foundation

/// Observable state for the search overlay and note navigation.
/// Shared between PanelContentView (SwiftUI) and PanelController (key monitor).
final class PanelState: ObservableObject {
    @Published var isSearchVisible: Bool = false
    @Published var searchQuery: String = ""
    @Published var selectedIndex: Int = 0
    @Published var searchResultCount: Int = 0

    /// Tracks whether the search text field has focus.
    /// Synced from @FocusState in PanelContentView because the key monitor
    /// in PanelController needs to know whether g/G should navigate search
    /// results or be forwarded to the text field.
    @Published var isSearchFieldFocused: Bool = false

    func toggleSearch() {
        if isSearchVisible {
            closeSearch()
        } else {
            isSearchVisible = true
            searchQuery = ""
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

    /// @param delta Direction to move: -1 for up, +1 for down.
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
