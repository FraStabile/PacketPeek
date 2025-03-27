//
//  Item.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 27/03/25.
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
