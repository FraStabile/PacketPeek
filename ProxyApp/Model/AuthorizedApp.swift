//
//  AuthorizedApp.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 28/04/25.
//


struct AuthorizedApp: Identifiable, Codable {
    var id: String { bundle_id }
    let bundle_id: String
    let name: String
    let decrypt_traffic: Bool
}