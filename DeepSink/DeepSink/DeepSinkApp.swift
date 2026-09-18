//
//  DeepSinkApp.swift
//  DeepSink
//

import SwiftUI
import SwiftData

@main
struct DeepSinkApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var liveAssistEngine = LiveAssistEngine()
    @StateObject private var routerClient: RouterClient
    @StateObject private var sessionProcessor: SessionProcessor

    init() {
        let router = RouterClient()
        _routerClient = StateObject(wrappedValue: router)
        _sessionProcessor = StateObject(wrappedValue: SessionProcessor(routerClient: router))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(audioRecorder)
                .environmentObject(liveAssistEngine)
                .environmentObject(routerClient)
                .environmentObject(sessionProcessor)
        }
        // Attaches a SwiftData store for these models to the whole view
        // hierarchy — any view below this can read/write via `@Query` and
        // `@Environment(\.modelContext)` without being handed anything
        // explicitly. Same pattern as yt-run's YTRunApp.
        .modelContainer(for: [Session.self, ActionItem.self, Marker.self])
    }
}
