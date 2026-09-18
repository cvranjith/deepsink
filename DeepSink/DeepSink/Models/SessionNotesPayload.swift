//
//  SessionNotesPayload.swift
//  DeepSink
//

import Foundation

// Mirrors deepsink.notes' response shape from requirement-deepsink-mobile.md
// FR-4 field for field. Every field is optional on purpose: a partial or
// slightly-off response from the router should degrade (missing sections
// just don't render) rather than fail to decode at all — FR-4 explicitly
// requires the app "never crash, never show a raw parse error."
struct SessionNotesPayload: Codable, Equatable {
    var title: String?
    var summary: String?
    var keyPoints: [String]?
    var decisions: [String]?
    var actionItems: [ActionItemPayload]?
    var openQuestions: [String]?

    enum CodingKeys: String, CodingKey {
        case title, summary
        case keyPoints = "key_points"
        case decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }
}

struct ActionItemPayload: Codable, Equatable {
    var text: String
    var owner: String?
    var due: String?
}
