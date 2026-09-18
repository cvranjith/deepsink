//
//  ActionItem.swift
//  DeepSink
//

import Foundation
import SwiftData

@Model
final class ActionItem {
    var id: UUID
    var text: String
    var owner: String?
    var due: String?
    var isChecked: Bool
    var sortOrder: Int
    var session: Session?

    init(id: UUID = UUID(), text: String, owner: String? = nil, due: String? = nil, sortOrder: Int = 0) {
        self.id = id
        self.text = text
        self.owner = owner
        self.due = due
        self.isChecked = false
        self.sortOrder = sortOrder
    }
}
