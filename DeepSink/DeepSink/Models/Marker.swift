//
//  Marker.swift
//  DeepSink
//

import Foundation
import SwiftData

@Model
final class Marker {
    var id: UUID
    var offsetSeconds: Double
    var comment: String?
    var photoFileName: String?
    var createdAt: Date
    var session: Session?

    init(id: UUID = UUID(), offsetSeconds: Double, comment: String? = nil, photoFileName: String? = nil) {
        self.id = id
        self.offsetSeconds = offsetSeconds
        self.comment = comment
        self.photoFileName = photoFileName
        self.createdAt = Date()
    }
}
