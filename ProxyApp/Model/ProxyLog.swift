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
    var responseTime: Double
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

    /// Lenient decoder: every backend field is treated as optional so a partial /
    /// best-effort log entry from the proxy still surfaces in the UI instead of
    /// being dropped silently.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        self.method          = (try? container.decodeIfPresent(String.self, forKey: .method))       ?? ""
        self.url             = (try? container.decodeIfPresent(String.self, forKey: .url))          ?? ""
        self.protocol        = (try? container.decodeIfPresent(String.self, forKey: .protocol))     ?? ""
        self.clientIP        = (try? container.decodeIfPresent(String.self, forKey: .clientIP))     ?? ""
        self.requestHeaders  = (try? container.decodeIfPresent([String: String].self, forKey: .requestHeaders)) ?? [:]
        self.requestBody     = try? container.decodeIfPresent(String.self, forKey: .requestBody)

        self.statusCode      = (try? container.decodeIfPresent(Int.self, forKey: .statusCode))      ?? 0
        self.responseHeaders = (try? container.decodeIfPresent([String: String].self, forKey: .responseHeaders)) ?? [:]
        self.responseBody    = try? container.decodeIfPresent(String.self, forKey: .responseBody)
        self.responseTime    = ((try? container.decodeIfPresent(Double.self, forKey: .responseTime)) ?? 0).rounded(.up)

        if let timestampString = try? container.decodeIfPresent(String.self, forKey: .timestamp),
           let parsed = formatter.date(from: timestampString) ?? fallbackFormatter.date(from: timestampString) {
            self.timestamp = parsed
        } else {
            self.timestamp = Date()
        }

        if let completedString = try? container.decodeIfPresent(String.self, forKey: .completed),
           let parsed = formatter.date(from: completedString) ?? fallbackFormatter.date(from: completedString) {
            self.completed = parsed
        } else {
            self.completed = self.timestamp
        }

        self.userAgent     = try? container.decodeIfPresent(String.self, forKey: .userAgent)
        self.deviceInfo    = try? container.decodeIfPresent(String.self, forKey: .deviceInfo)
        self.isSimulator   = (try? container.decodeIfPresent(Bool.self, forKey: .isSimulator)) ?? false
        self.appIdentifier = try? container.decodeIfPresent(String.self, forKey: .appIdentifier)
    }

    init(
        method: String = "",
        url: String = "",
        `protocol`: String = "",
        clientIP: String = "",
        requestHeaders: [String: String] = [:],
        requestBody: String? = nil,
        statusCode: Int = 200,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        responseTime: Double = 0.0,
        timestamp: Date = Date(),
        completed: Date = Date(),
        userAgent: String? = nil,
        deviceInfo: String? = nil,
        isSimulator: Bool = false,
        appIdentifier: String? = nil
    ) {
        self.method = method
        self.url = url
        self.`protocol` = `protocol`
        self.clientIP = clientIP
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.responseTime = responseTime
        self.timestamp = timestamp
        self.completed = completed
        self.userAgent = userAgent
        self.deviceInfo = deviceInfo
        self.isSimulator = isSimulator
        self.appIdentifier = appIdentifier
    }
}
