//
//  ProxyLog.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 10/04/25.
//


import Foundation

struct ProxyLog: Codable, Hashable, Identifiable {
    var id = UUID()
    // Request info
    var method: String
    var url: String
    var `protocol`: String
    var clientIP: String
    var requestHeaders: [String: String]
    var requestBody: String?

    // Response info
    var statusCode: Int
    var responseHeaders: [String: String]
    var responseBody: String?
    var responseTime: Double // Se il tempo di risposta è un numero
    var timestamp: Date
    var completed: Date

    // Device info
    var userAgent: String?
    var deviceInfo: String?
    var isSimulator: Bool
    var appIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case method, url, `protocol`, clientIP = "client_ip", requestHeaders = "request_headers", requestBody = "request_body"
        case statusCode = "status_code", responseHeaders = "response_headers", responseBody = "response_body"
        case responseTime = "response_time_ms", timestamp, completed
        case userAgent = "user_agent", deviceInfo = "device_info", isSimulator = "is_simulator", appIdentifier = "app_identifier"
    }

    // Custom decoder per trattare il timestamp come stringa
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.method = try container.decode(String.self, forKey: .method)
        self.url = try container.decode(String.self, forKey: .url)
        self.protocol = try container.decode(String.self, forKey: .protocol)
        self.clientIP = try container.decode(String.self, forKey: .clientIP)
        self.requestHeaders = try container.decode([String: String].self, forKey: .requestHeaders)
        self.requestBody = try container.decodeIfPresent(String.self, forKey: .requestBody)

        self.statusCode = try container.decode(Int.self, forKey: .statusCode)
        self.responseHeaders = try container.decode([String: String].self, forKey: .responseHeaders)
        self.responseBody = try container.decodeIfPresent(String.self, forKey: .responseBody)
        self.responseTime = try container.decode(Double.self, forKey: .responseTime).rounded(.up)

        // Se il timestamp è una stringa, usa un DateFormatter per convertirlo in Date
        let timestampString = try container.decode(String.self, forKey: .timestamp)
        let formatter = ISO8601DateFormatter()
        self.timestamp = formatter.date(from: timestampString) ?? Date()

        let completedString = try container.decode(String.self, forKey: .completed)
        self.completed = formatter.date(from: completedString) ?? Date()

        self.userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        self.deviceInfo = try container.decodeIfPresent(String.self, forKey: .deviceInfo)
        self.isSimulator = try container.decode(Bool.self, forKey: .isSimulator)
        self.appIdentifier = try container.decodeIfPresent(String.self, forKey: .appIdentifier)
    }
}

