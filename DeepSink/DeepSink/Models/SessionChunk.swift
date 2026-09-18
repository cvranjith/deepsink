//
//  SessionChunk.swift
//  DeepSink
//

import Foundation

// One rotated audio segment recorded by AudioRecorder — purely a
// description of a finished local file (index, name, timing), handed to
// AudioRecorder's `onChunkFinished` callback. `index` is a monotonically
// increasing counter for the whole recording (not just the array
// position), so it stays a stable identifier even across an interruption
// that leaves a gap.
//
// No longer carries an `isTranscribed` flag: chunks now upload to the
// server as soon as they're produced (see ContentView's chunk-upload
// flow), not batched and resent later, so there's nothing local left to
// track per chunk once it's been handed off.
struct SessionChunk: Codable, Identifiable, Hashable {
    var id: Int { index }
    var index: Int
    var fileName: String
    var startOffsetSeconds: Double
    var durationSeconds: Double
}
