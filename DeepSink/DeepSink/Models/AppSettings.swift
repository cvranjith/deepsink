//
//  AppSettings.swift
//  DeepSink
//

import Foundation
import Combine

// Same `ObservableObject` + `@Published` pattern as yt-run's AppSettings
// (see that project for the fuller explanation) — one difference:
// `routerToken` persists to Keychain instead of UserDefaults, since this
// app's token gates real meeting content (see KeychainStore).
final class AppSettings: ObservableObject {
    private enum Keys {
        static let routerURL = "routerURL"
        static let chunkTargetSeconds = "chunkTargetSeconds"
        static let announceRecordingReminder = "announceRecordingReminder"
        static let liveAssistEnabled = "liveAssistEnabled"
        static let attentionKeywords = "attentionKeywords"
        static let articulateWindowSeconds = "articulateWindowSeconds"
    }

    private enum KeychainAccounts {
        static let routerToken = "routerToken"
    }

    private enum Defaults {
        // 3 minutes — long enough that most chunks land on a natural
        // pause in conversation without the level-meter/silence check
        // in AudioRecorder waiting too long past it; short enough that a
        // failed upload only ever has to redo a few minutes of audio.
        static let chunkTargetSeconds = 180
        // 3 minutes — long enough to catch a question asked a little
        // before you tuned back in, short enough that Articulate's
        // answer stays focused and the model call stays fast.
        static let articulateWindowSeconds = 180
    }

    @Published var routerURL: String {
        didSet { UserDefaults.standard.set(routerURL, forKey: Keys.routerURL) }
    }

    @Published var routerToken: String {
        didSet { KeychainStore.write(routerToken, account: KeychainAccounts.routerToken) }
    }

    // Target chunk length before AudioRecorder looks for a quiet moment
    // to cut — see AudioRecorder's own comments for the full rotation
    // logic. Exposed per FR-7 ("cheap to expose").
    @Published var chunkTargetSeconds: Int {
        didSet { UserDefaults.standard.set(chunkTargetSeconds, forKey: Keys.chunkTargetSeconds) }
    }

    // Section 5's consent nudge — an on-screen reminder shown the moment
    // recording starts, to say out loud that the room is being recorded.
    // Recording consent law varies by jurisdiction; that's the user's
    // call to make, not this app's (see README).
    @Published var announceRecordingReminder: Bool {
        didSet { UserDefaults.standard.set(announceRecordingReminder, forKey: Keys.announceRecordingReminder) }
    }

    // Off by default — an additional permission (Speech Recognition) and
    // ongoing battery/CPU cost on top of plain recording, so it's opt-in
    // rather than always-on. See LiveAssistEngine.
    @Published var liveAssistEnabled: Bool {
        didSet { UserDefaults.standard.set(liveAssistEnabled, forKey: Keys.liveAssistEnabled) }
    }

    // Usually just the user's own name. Matched case-insensitively as a
    // substring of whatever LiveAssistEngine recognizes.
    @Published var attentionKeywords: [String] {
        didSet { UserDefaults.standard.set(attentionKeywords, forKey: Keys.attentionKeywords) }
    }

    // How far back Articulate looks when tapped — see
    // LiveAssistEngine.recentTranscript.
    @Published var articulateWindowSeconds: Int {
        didSet { UserDefaults.standard.set(articulateWindowSeconds, forKey: Keys.articulateWindowSeconds) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.routerURL = defaults.string(forKey: Keys.routerURL) ?? ""
        self.routerToken = KeychainStore.read(account: KeychainAccounts.routerToken) ?? ""
        self.chunkTargetSeconds = defaults.object(forKey: Keys.chunkTargetSeconds) as? Int ?? Defaults.chunkTargetSeconds
        self.announceRecordingReminder = defaults.object(forKey: Keys.announceRecordingReminder) as? Bool ?? true
        self.liveAssistEnabled = defaults.bool(forKey: Keys.liveAssistEnabled)
        self.attentionKeywords = defaults.stringArray(forKey: Keys.attentionKeywords) ?? []
        self.articulateWindowSeconds = defaults.object(forKey: Keys.articulateWindowSeconds) as? Int ?? Defaults.articulateWindowSeconds
    }
}
