//
//  SettingsProtocol.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 24/04/25.
//


import SwiftUI

protocol SettingsItemProtocol: Identifiable {
    var id: UUID { get }
    var name: String { get }
    var icon: String? { get }
    associatedtype Content: View
    @ViewBuilder func content() -> Content
}

