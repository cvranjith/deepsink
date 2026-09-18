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
// No explicit CodingKeys — decoded via DeepSinkSession's shared decoder
// (RouterClient.sessionDecoder), which sets keyDecodingStrategy =
// .convertFromSnakeCase globally, so "key_points" -> keyPoints etc.
// happen automatically. (Explicit CodingKeys would actually break this:
// the strategy converts the JSON's own keys before matching against
// CodingKeys' raw values, so a raw value already spelled "key_points"
// would no longer match the converted "keyPoints".)
struct SessionNotesPayload: Codable, Equatable {
    var title: String?
    var summary: String?
    var keyPoints: [String]?
    var decisions: [String]?
    var actionItems: [ActionItemPayload]?
    var openQuestions: [String]?
}

struct ActionItemPayload: Codable, Equatable {
    var text: String
    var owner: String?
    var due: String?
}
