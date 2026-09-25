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
        static let gatewayURL = "gatewayURL"
        static let chunkTargetSeconds = "chunkTargetSeconds"
        static let announceRecordingReminder = "announceRecordingReminder"
        static let liveAssistEnabled = "liveAssistEnabled"
        static let liveNotesEnabled = "liveNotesEnabled"
        static let diarizationEnabled = "diarizationEnabled"
        static let attentionKeywords = "attentionKeywords"
        static let articulateWindowSeconds = "articulateWindowSeconds"
        static let deepSinkUserID = "deepSinkUserID"
    }

    private enum KeychainAccounts {
        static let deepSinkPassword = "deepSinkPassword"
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

    // The Mac mini's ai-gateway — one URL, its Tailscale Funnel address
    // (e.g. "https://ranjiths-mac-mini.tailXXXX.ts.net/gateway", already
    // including its "/gateway" Caddy prefix), always reachable regardless
    // of network. RouterClient discovers the Mac's current LAN address
    // itself at runtime (by asking the gateway, over this same URL, what
    // its own local IP currently is) and prefers that when reachable —
    // see RouterClient's own doc comment. No second URL to maintain here,
    // and nothing here drifts under DHCP since it's rediscovered fresh
    // each time rather than typed in once and going stale.
    @Published var gatewayURL: String {
        didSet { UserDefaults.standard.set(gatewayURL, forKey: Keys.gatewayURL) }
    }

    // DeepSink's own login (ai-gateway's user_auth.py) — the only
    // credential this app needs now. Exchanged for a JWT by RouterClient
    // (cached in memory there, never stored itself beyond this Keychain
    // entry) that authenticates everything: both `/invoke` (Articulate,
    // Update App) and `/deepsink/sessions/*` (session data) accept it —
    // no separate client_id/secret anymore.
    @Published var deepSinkUserID: String {
        didSet { UserDefaults.standard.set(deepSinkUserID, forKey: Keys.deepSinkUserID) }
    }

    @Published var deepSinkPassword: String {
        didSet { KeychainStore.write(deepSinkPassword, account: KeychainAccounts.deepSinkPassword) }
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

    // The default for a new recording's own live_notes_enabled (server-side
    // per-session field — see session_store.py) - whether notes/action
    // items regenerate automatically after every chunk ("live") or only
    // when explicitly asked ("record now, polish once at the end"). On by
    // default, matching the behavior before this setting existed. Each
    // session can still be flipped independently mid-recording
    // (SessionDetailView's own toggle), so this is just what a fresh
    // recording starts with, not a global lock.
    @Published var liveNotesEnabled: Bool {
        didSet { UserDefaults.standard.set(liveNotesEnabled, forKey: Keys.liveNotesEnabled) }
    }

    // The default for a new recording's own diarization_enabled
    // (server-side per-session field). Off skips speaker detection
    // entirely and, since that's the only reason the server keeps raw
    // audio around past transcription, deletes each chunk's audio right
    // after it transcribes instead of waiting for the whole recording to
    // finish - see upload_chunk's own comment server-side.
    @Published var diarizationEnabled: Bool {
        didSet { UserDefaults.standard.set(diarizationEnabled, forKey: Keys.diarizationEnabled) }
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
        self.gatewayURL = defaults.string(forKey: Keys.gatewayURL) ?? ""
        self.deepSinkUserID = defaults.string(forKey: Keys.deepSinkUserID) ?? ""
        self.deepSinkPassword = KeychainStore.read(account: KeychainAccounts.deepSinkPassword) ?? ""
        self.chunkTargetSeconds = defaults.object(forKey: Keys.chunkTargetSeconds) as? Int ?? Defaults.chunkTargetSeconds
        self.announceRecordingReminder = defaults.object(forKey: Keys.announceRecordingReminder) as? Bool ?? true
        self.liveAssistEnabled = defaults.bool(forKey: Keys.liveAssistEnabled)
        self.liveNotesEnabled = defaults.object(forKey: Keys.liveNotesEnabled) as? Bool ?? true
        self.diarizationEnabled = defaults.object(forKey: Keys.diarizationEnabled) as? Bool ?? true
        self.attentionKeywords = defaults.stringArray(forKey: Keys.attentionKeywords) ?? []
        self.articulateWindowSeconds = defaults.object(forKey: Keys.articulateWindowSeconds) as? Int ?? Defaults.articulateWindowSeconds
    }
}
