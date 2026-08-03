//
//  Item.swift
//  speech_note
//
//  Created by scott on 2026/8/3.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
