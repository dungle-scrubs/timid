import SwiftUI

/// Scrollable list of fuzzy-matched search results with keyboard selection highlighting.
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
