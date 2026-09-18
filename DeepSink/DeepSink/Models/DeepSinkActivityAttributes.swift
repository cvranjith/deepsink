//
//  DeepSinkActivityAttributes.swift
//  DeepSink
//

import ActivityKit
import Foundation

// The data contract for the Lock Screen / Dynamic Island Live Activity
// shown while recording. This file must belong to BOTH the main app
// target (AudioRecorder starts/updates it) and the DeepSinkActivity
// widget extension target (which renders it) — they run as separate
// processes, so ActivityKit needs this exact type available to both
// sides. Same pattern as yt-run's RunActivityAttributes.
//
// NOTE: if this file is ever recreated from scratch (rather than edited
// in place), its Xcode File Inspector -> Target Membership must have
// BOTH "DeepSink" and "DeepSinkActivityExtension" checked.
struct DeepSinkActivityAttributes: ActivityAttributes {
    var startedAt: Date

    public struct ContentState: Codable, Hashable {
        var elapsedSeconds: Int
        var isRecording: Bool
    }
}
