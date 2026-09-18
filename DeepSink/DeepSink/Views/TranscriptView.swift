//
//  TranscriptView.swift
//  DeepSink
//

import SwiftUI
import AVFoundation

// FR-9: transcript as browsable, timestamped blocks rather than one wall
// of text. Tapping a block plays the audio chunk that covers it, seeked
// to the block's own offset within that chunk — chunks are separate
// files (see AudioRecorder), so this plays the specific chunk rather
// than stitching all of a session's audio into one continuous track.
struct TranscriptView: View {
    let session: Session
    @State private var player: AVAudioPlayer?
    @State private var playingBlockID: UUID?
    @State private var playbackError: String?

    var body: some View {
        List {
            if session.audioDeleted {
                Text("Audio has been deleted — transcript text is still available, but blocks can't be played back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(session.transcriptBlocks.sorted(by: { $0.startSeconds < $1.startSeconds })) { block in
                Button {
                    play(block: block)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(formattedOffset(block.startSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Text(block.text)
                            .foregroundStyle(.primary)
                        Spacer()
                        if playingBlockID == block.id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(session.audioDeleted)
            }
        }
        .navigationTitle("Transcript")
        .alert("Playback", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playbackError ?? "")
        }
        .onDisappear { player?.stop() }
    }

    private func play(block: TranscriptBlock) {
        guard let chunk = session.chunks.first(where: {
            block.startSeconds >= $0.startOffsetSeconds && block.startSeconds < $0.startOffsetSeconds + $0.durationSeconds
        }) else {
            playbackError = "Couldn't find the audio for this moment."
            return
        }
        let url = AudioRecorder.audioDirectory.appendingPathComponent(chunk.fileName)
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            newPlayer.currentTime = max(0, block.startSeconds - chunk.startOffsetSeconds)
            newPlayer.play()
            player = newPlayer
            playingBlockID = block.id
        } catch {
            playbackError = "Couldn't play this chunk: \(error.localizedDescription)"
        }
    }

    private func formattedOffset(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
