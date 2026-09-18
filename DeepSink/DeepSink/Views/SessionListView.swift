//
//  SessionListView.swift
//  DeepSink
//

import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var routerClient: RouterClient
    @EnvironmentObject var sessionStore: DeepSinkSessionStore

    var body: some View {
        List {
            if sessionStore.sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "waveform",
                    description: Text("Recordings you stop will show up here.")
                )
            }
            ForEach(sessionStore.sessions) { session in
                NavigationLink {
                    SessionDetailView(session: session)
                } label: {
                    row(for: session)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Sessions")
        .refreshable {
            await sessionStore.refresh(settings: settings)
        }
    }

    private func row(for session: DeepSinkSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.headline)
            HStack(spacing: 6) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(formattedDuration(session.durationSeconds))
                Text("·")
                Text(session.stageLabel)
                if session.openActionItemCount > 0 {
                    Text("· \(session.openActionItemCount) open")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { sessionStore.sessions[$0] }
        for session in toDelete {
            sessionStore.remove(id: session.id)
            Task { _ = await routerClient.deleteSession(id: session.id, settings: settings) }
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

#Preview {
    let router = RouterClient()
    return NavigationStack {
        SessionListView()
    }
    .environmentObject(AppSettings())
    .environmentObject(router)
    .environmentObject(DeepSinkSessionStore(routerClient: router))
}
