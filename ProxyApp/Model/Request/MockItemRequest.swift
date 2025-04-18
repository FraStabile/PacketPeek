//
//  MockItemRequest.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 16/04/25.
//


import Foundation

// MARK: - MockItemRequest
struct MockItemRequest: Codable, Equatable, Hashable, Identifiable {
    var id: String
    let method, host, path: String
    let isRegex: Bool
    let statusCode, latencyMS: Int
    let response, contentType: String
    var isActive: Bool
    enum CodingKeys: String, CodingKey {
        case method, host, path
        case isRegex = "is_regex"
        case statusCode = "status_code"
        case latencyMS = "latency_ms"
        case response
        case contentType = "content_type"
        case isActive = "is_active"
        case id
    }
    
    init(method: String, host: String, path: String, isRegex: Bool, statusCode: Int, latencyMS: Int, response: String, contentType: String, isActive: Bool, id: String = "") {
        self.method = method
        self.host = host
        self.path = path
        self.isRegex = isRegex
        self.statusCode = statusCode
        self.latencyMS = latencyMS
        self.response = response
        self.contentType = contentType
        self.isActive = isActive
        self.id = id
    }
}
