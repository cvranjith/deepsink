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
        static let deleteAudioAfterDays = "deleteAudioAfterDays"
        static let announceRecordingReminder = "announceRecordingReminder"
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
        static let deleteAudioAfterDays = 7
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

    // Days after a session reaches `.ready` before its audio chunks are
    // deleted automatically — 0 means keep indefinitely. See
    // SessionProcessor.purgeExpiredAudio.
    @Published var deleteAudioAfterDays: Int {
        didSet { UserDefaults.standard.set(deleteAudioAfterDays, forKey: Keys.deleteAudioAfterDays) }
    }

    // Section 5's consent nudge — an on-screen reminder shown the moment
    // recording starts, to say out loud that the room is being recorded.
    // Recording consent law varies by jurisdiction; that's the user's
    // call to make, not this app's (see README).
    @Published var announceRecordingReminder: Bool {
        didSet { UserDefaults.standard.set(announceRecordingReminder, forKey: Keys.announceRecordingReminder) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.routerURL = defaults.string(forKey: Keys.routerURL) ?? ""
        self.routerToken = KeychainStore.read(account: KeychainAccounts.routerToken) ?? ""
        self.chunkTargetSeconds = defaults.object(forKey: Keys.chunkTargetSeconds) as? Int ?? Defaults.chunkTargetSeconds
        self.deleteAudioAfterDays = defaults.object(forKey: Keys.deleteAudioAfterDays) as? Int ?? Defaults.deleteAudioAfterDays
        self.announceRecordingReminder = defaults.object(forKey: Keys.announceRecordingReminder) as? Bool ?? true
    }
}
