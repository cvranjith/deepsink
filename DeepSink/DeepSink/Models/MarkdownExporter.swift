//
//  MarkdownExporter.swift
//  DeepSink
//

import Foundation

// FR-6: export as markdown (with `- [ ]`/`- [x]` action items, so it
// pastes usefully into a notes system) and as plain text, both via the
// standard share sheet — see ActivityView.
enum MarkdownExporter {
    static func markdown(for session: Session) -> String {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("_\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(formattedDuration(session.durationSeconds))_")
        lines.append("")

        if let summary = session.notes?.summary, !summary.isEmpty {
            lines.append("## Summary")
            lines.append(summary)
            lines.append("")
        }
        if let keyPoints = session.notes?.keyPoints, !keyPoints.isEmpty {
            lines.append("## Key points")
            keyPoints.forEach { lines.append("- \($0)") }
            lines.append("")
        }
        if let decisions = session.notes?.decisions, !decisions.isEmpty {
            lines.append("## Decisions")
            decisions.forEach { lines.append("- \($0)") }
            lines.append("")
        }
        if !session.actionItems.isEmpty {
            lines.append("## Action items")
            for item in session.actionItems.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                let box = item.isChecked ? "[x]" : "[ ]"
                var line = "- \(box) \(item.text)"
                var meta: [String] = []
                if let owner = item.owner, !owner.isEmpty, owner != "unknown" { meta.append("owner: \(owner)") }
                if let due = item.due, !due.isEmpty { meta.append("due: \(due)") }
                if !meta.isEmpty { line += " (\(meta.joined(separator: ", ")))" }
                lines.append(line)
            }
            lines.append("")
        }
        if let openQuestions = session.notes?.openQuestions, !openQuestions.isEmpty {
            lines.append("## Open questions")
            openQuestions.forEach { lines.append("- \($0)") }
            lines.append("")
        }
        if !session.markers.isEmpty {
            lines.append("## Markers")
            for marker in session.markers.sorted(by: { $0.offsetSeconds < $1.offsetSeconds }) {
                var line = "- \(formattedDuration(marker.offsetSeconds))"
                if let comment = marker.comment, !comment.isEmpty { line += " — \(comment)" }
                lines.append(line)
            }
            lines.append("")
        }
        if !session.fullTranscript.isEmpty {
            lines.append("## Transcript")
            lines.append(session.fullTranscript)
        }
        return lines.joined(separator: "\n")
    }

    static func plainText(for session: Session) -> String {
        markdown(for: session)
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .replacingOccurrences(of: "- [x] ", with: "[x] ")
            .replacingOccurrences(of: "- [ ] ", with: "[ ] ")
            .replacingOccurrences(of: "- ", with: "• ")
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
