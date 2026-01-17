import SwiftUI

struct MarkdownView: View {
    let content: String

    var body: some View {
        Text(attributedContent)
            .textSelection(.enabled)
    }

    private var attributedContent: AttributedString {
        do {
            var attributed = try AttributedString(markdown: strippedContent, options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            ))

            // Apply base styling
            attributed.font = .body
            attributed.foregroundColor = .primary

            return attributed
        } catch {
            return AttributedString(strippedContent)
        }
    }

    // Strip YAML frontmatter if present
    private var strippedContent: String {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return content }

        var inFrontmatter = true
        var resultLines: [String] = []

        for (index, line) in lines.enumerated() {
            if index == 0 {
                continue
            }
            if inFrontmatter && line == "---" {
                inFrontmatter = false
                continue
            }
            if !inFrontmatter {
                resultLines.append(line)
            }
        }

        return resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
