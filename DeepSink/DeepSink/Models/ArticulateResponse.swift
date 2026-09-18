//
//  ArticulateResponse.swift
//  DeepSink
//

import Foundation

// deepsink.articulate's response shape — quick-reference bullets plus a
// spoken-style draft, both generated from the same short transcript
// excerpt in one call. See RouterClient.articulate and ArticulateSheet.
struct ArticulateResponse: Codable, Equatable {
    var bullets: [String]
    var speech: String
}
