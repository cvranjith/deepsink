//
//  SessionCard.swift
//  DeepSink
//

import SwiftUI

// A compact card summarizing one session, used on the home screen's
// "Recent" section (see ContentView) — a glanceable alternative to
// SessionListView's plain rows, matching the card-based home screens of
// comparable apps rather than this app's original single-button empty
// screen.
struct SessionCard: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                stateBadge
            }
            HStack(spacing: 6) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(formattedDuration(session.durationSeconds))
                if session.openActionItemCount > 0 {
                    Text("· \(session.openActionItemCount) open")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let summary = session.notes?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    private var stateBadge: some View {
        Text(session.state.label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.15), in: Capsule())
            .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch session.state.stage {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
