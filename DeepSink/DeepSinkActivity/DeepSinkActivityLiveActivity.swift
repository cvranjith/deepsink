//
//  DeepSinkActivityLiveActivity.swift
//  DeepSinkActivity
//

import ActivityKit
import WidgetKit
import SwiftUI

struct DeepSinkActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeepSinkActivityAttributes.self) { context in
            // Lock Screen / banner UI.
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text(formattedDuration(context.state.elapsedSeconds))
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                    Text("DeepSink recording")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()
            }
            .foregroundStyle(.white)
            .padding()
            .activityBackgroundTint(Color(red: 0.75, green: 0.1, blue: 0.12))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(formattedDuration(context.state.elapsedSeconds), systemImage: "mic.fill")
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Recording")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("DeepSink · meeting in progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
            } compactTrailing: {
                Text(formattedDuration(context.state.elapsedSeconds))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "mic.fill")
            }
        }
    }
}

private func formattedDuration(_ seconds: Int) -> String {
    String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

extension DeepSinkActivityAttributes {
    fileprivate static var preview: DeepSinkActivityAttributes {
        DeepSinkActivityAttributes(startedAt: Date())
    }
}

extension DeepSinkActivityAttributes.ContentState {
    fileprivate static var early: DeepSinkActivityAttributes.ContentState {
        DeepSinkActivityAttributes.ContentState(elapsedSeconds: 180, isRecording: true)
    }

    fileprivate static var midMeeting: DeepSinkActivityAttributes.ContentState {
        DeepSinkActivityAttributes.ContentState(elapsedSeconds: 1980, isRecording: true)
    }
}

#Preview("Notification", as: .content, using: DeepSinkActivityAttributes.preview) {
   DeepSinkActivityLiveActivity()
} contentStates: {
    DeepSinkActivityAttributes.ContentState.early
    DeepSinkActivityAttributes.ContentState.midMeeting
}
