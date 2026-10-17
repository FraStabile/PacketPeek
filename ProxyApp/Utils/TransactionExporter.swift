//
//  TransactionExporter.swift
//  ProxyApp
//

import Foundation

/// Pure builder of the TXT export (no UI), so redaction can be unit-tested.
enum TransactionExporter {
    static func text(for request: ProxyLog, revealSensitive: Bool = false) -> String {
        let reqHeaders = headerLines(request.requestHeaders, reveal: revealSensitive)
        let resHeaders = headerLines(request.responseHeaders, reveal: revealSensitive)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return """
            📦 HTTP Transaction Export
            ============================

            📬 REQUEST
            ----------------------------
            🕒 Timestamp: \(formatter.string(from: request.timestamp))
            🔗 URL: \(request.url)
            📬 Method: \(request.method)
            📱 User-Agent: \(request.userAgent ?? "N/A")

            🧾 Headers:
            \(reqHeaders)

            📝 Body:
            \(request.requestBody ?? "<empty>")


            📥 RESPONSE
            ----------------------------
            📡 Status: \(request.statusCode)
            ⏱ Duration: \(String(format: "%.2f", request.responseTime)) ms
            🧾 Headers:
            \(resHeaders)

            📝 Body:
            \(request.responseBody ?? "<empty>")
            """
    }

    private static func headerLines(_ headers: [String: String], reveal: Bool) -> String {
        HeaderRedactor.redact(headers, reveal: reveal)
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }
}
