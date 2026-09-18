//
//  SessionChunk.swift
//  DeepSink
//

import Foundation

// One rotated audio segment recorded by AudioRecorder. `index` is a
// monotonically increasing counter for the whole session (not just the
// array position), so it stays a stable identifier for a chunk even
// across an interruption that leaves a gap. `isTranscribed` is what
// makes FR-3's "retry outstanding chunks rather than starting over"
// possible: SessionProcessor only ever resends chunks where this is
// still false, and it's persisted on the Session itself, so it survives
// the app being killed mid-upload.
struct SessionChunk: Codable, Identifiable, Hashable {
    var id: Int { index }
    var index: Int
    var fileName: String
    var startOffsetSeconds: Double
    var durationSeconds: Double
    var isTranscribed: Bool = false
}
