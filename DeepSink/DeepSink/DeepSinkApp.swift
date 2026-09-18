//
//  DeepSinkApp.swift
//  DeepSink
//

import SwiftUI

@main
struct DeepSinkApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var liveAssistEngine = LiveAssistEngine()
    @StateObject private var routerClient: RouterClient
    @StateObject private var sessionStore: DeepSinkSessionStore

    init() {
        let router = RouterClient()
        _routerClient = StateObject(wrappedValue: router)
        _sessionStore = StateObject(wrappedValue: DeepSinkSessionStore(routerClient: router))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(audioRecorder)
                .environmentObject(liveAssistEngine)
                .environmentObject(routerClient)
                .environmentObject(sessionStore)
        }
        // No .modelContainer anymore — the server is the only store of
        // session data now (see DeepSinkSession's doc comment); sessionStore
        // is just an in-memory cache of the server's list, refreshed on
        // demand rather than attached as a persistence layer.
    }
}
