//
//  OutstandingActionsView.swift
//  DeepSink
//

import SwiftUI

// Cross-session "what's still outstanding" dashboard - fetches the
// flattened rollup from GET /deepsink/action_items (see that route's
// own comment in deepsink_sessions.py) and re-groups it by session for
// display. Every mutation here (toggle, owner/due edit) round-trips
// through the exact same per-item PATCH endpoint SessionDetailView's
// own Actions tab uses, so there's no separate "dashboard" copy of an
// item's state - just a different view over the same data. Mirrors the
// web viewer's own Outstanding Actions page.
struct OutstandingActionsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var routerClient: RouterClient
    @EnvironmentObject var sessionStore: DeepSinkSessionStore

    @State private var items: [OutstandingActionItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var mineOnly = false
    @State private var showCompleted = false

    @State private var editingItem: OutstandingActionItem?
    @State private var editOwnerText = ""
    @State private var editDueText = ""

    private struct Group: Identifiable {
        var id: String { sessionId }
        var sessionId: String
        var sessionTitle: String
        var items: [OutstandingActionItem]
    }

    // Preserves the rollup's own soonest-due-first order, just
    // clustering consecutive items under the same session rather than
    // re-sorting by session - same approach as the web dashboard.
    private var visibleGroups: [Group] {
        let filtered = items
            .filter { showCompleted || !$0.isChecked }
            .filter { !mineOnly || $0.owner == "You" }
        var groups: [Group] = []
        for item in filtered {
            if groups.last?.sessionId == item.sessionId {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(Group(sessionId: item.sessionId, sessionTitle: item.sessionTitle, items: [item]))
            }
        }
        return groups
    }

    var body: some View {
        List {
            Section {
                Toggle("Only mine (You)", isOn: $mineOnly)
                Toggle("Show completed", isOn: $showCompleted)
            }

            if isLoading && items.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if visibleGroups.isEmpty {
                ContentUnavailableView(
                    "All caught up",
                    systemImage: "checkmark.circle",
                    description: Text("No outstanding action items.")
                )
            } else {
                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.items) { item in
                            row(for: item)
                        }
                    } header: {
                        NavigationLink {
                            destination(sessionId: group.sessionId)
                        } label: {
                            Text(group.sessionTitle)
                        }
                    }
                }
            }
        }
        .navigationTitle("Outstanding Actions")
        .refreshable { await load() }
        .task { await load() }
        .alert("Edit Action Item", isPresented: Binding(
            get: { editingItem != nil },
            set: { if !$0 { editingItem = nil } }
        )) {
            TextField("Owner", text: $editOwnerText)
            TextField("Due (e.g. 2026-10-05)", text: $editDueText)
            Button("Cancel", role: .cancel) { editingItem = nil }
            Button("Save") {
                if let item = editingItem { saveEdit(item) }
                editingItem = nil
            }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func destination(sessionId: String) -> some View {
        if let session = sessionStore.session(id: sessionId) {
            SessionDetailView(session: session)
        } else {
            Text("Session not found")
        }
    }

    private func row(for item: OutstandingActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                toggle(item)
            } label: {
                Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isChecked ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .strikethrough(item.isChecked)
                    .foregroundStyle(item.isChecked ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(item.owner?.isEmpty == false ? item.owner! : "Owner?")
                    Text("·")
                    Text(item.due?.isEmpty == false ? item.due! : "Due?")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingItem = item
            editOwnerText = item.owner ?? ""
            editDueText = item.due ?? ""
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch await routerClient.listOutstandingActionItems(settings: settings) {
        case .success(let fetched):
            items = fetched
        case .failure(let error):
            errorMessage = error.message
        }
    }

    private func toggle(_ item: OutstandingActionItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let newValue = !item.isChecked
        items[index].isChecked = newValue
        Task {
            let result = await routerClient.toggleActionItem(sessionID: item.sessionId, itemID: item.id, isChecked: newValue, settings: settings)
            if case .failure(let error) = result {
                items[index].isChecked = !newValue
                errorMessage = error.message
            }
        }
    }

    private func saveEdit(_ item: OutstandingActionItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let owner = editOwnerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let due = editDueText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await routerClient.updateActionItem(sessionID: item.sessionId, itemID: item.id, owner: owner, due: due, settings: settings)
            switch result {
            case .success:
                items[index].owner = owner.isEmpty ? nil : owner
                items[index].due = due.isEmpty ? nil : due
            case .failure(let error):
                errorMessage = error.message
            }
        }
    }
}

#Preview {
    let router = RouterClient()
    return NavigationStack {
        OutstandingActionsView()
    }
    .environmentObject(AppSettings())
    .environmentObject(router)
    .environmentObject(DeepSinkSessionStore(routerClient: router))
}
