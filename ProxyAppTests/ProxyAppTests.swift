//
//  ProxyAppTests.swift
//  ProxyAppTests
//
//  Created by Francesco Stabile on 27/03/25.
//

import Foundation
import Network
import Testing
@testable import PacketPeek

struct ProxyLogDecodingTests {

    @Test func decodesFullPayload() throws {
        let json = """
        {"method":"POST","url":"https://example.com/a?b=1","protocol":"HTTP/2.0","client_ip":"10.0.0.2",
         "request_headers":{"Accept":"*/*"},"request_body":"{}","status_code":201,
         "response_headers":{"Content-Type":"application/json"},"response_body":"ok",
         "response_time_ms":12.2,"timestamp":"2025-04-10T10:00:00.123Z","completed":"2025-04-10T10:00:01Z",
         "mocked":true,"is_simulator":true}
        """
        let log = try JSONDecoder().decode(ProxyLog.self, from: Data(json.utf8))
        #expect(log.method == "POST")
        #expect(log.url == "https://example.com/a?b=1")
        #expect(log.clientIP == "10.0.0.2")
        #expect(log.statusCode == 201)
        #expect(log.requestHeaders["Accept"] == "*/*")
        #expect(log.isMocked)
        #expect(log.isSimulator)
        // fractional ms are rounded up
        #expect(log.responseTime == 13)
    }

    @Test func decodesPartialPayloadWithDefaults() throws {
        let log = try JSONDecoder().decode(ProxyLog.self, from: Data("{}".utf8))
        #expect(log.method == "")
        #expect(log.statusCode == 0)
        #expect(log.requestHeaders.isEmpty)
        #expect(log.requestBody == nil)
        #expect(!log.isMocked)
        #expect(log.completed == log.timestamp)
    }

    @Test func invalidFieldTypesFallBackToDefaults() throws {
        let json = #"{"method":"GET","status_code":"oops","request_headers":[1,2]}"#
        let log = try JSONDecoder().decode(ProxyLog.self, from: Data(json.utf8))
        #expect(log.method == "GET")
        #expect(log.statusCode == 0)
        #expect(log.requestHeaders.isEmpty)
    }
}

struct MockItemRequestTests {

    @Test func encodesSnakeCaseKeys() throws {
        let mock = MockItemRequest(method: "GET", host: "api.example.com", path: "/v1", isRegex: false,
                                   statusCode: 200, latencyMS: 5, response: "{}",
                                   contentType: "application/json", isActive: true, id: "m1")
        let data = try JSONEncoder().encode(mock)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["is_regex"] as? Bool == false)
        #expect(dict["status_code"] as? Int == 200)
        #expect(dict["latency_ms"] as? Int == 5)
        #expect(dict["content_type"] as? String == "application/json")
        #expect(dict["is_active"] as? Bool == true)
    }

    @Test func roundTrips() throws {
        let mock = MockItemRequest(method: "POST", host: "h", path: "^/x", isRegex: true,
                                   statusCode: 404, latencyMS: 0, response: "", contentType: "text/plain",
                                   isActive: false, id: "abc")
        let decoded = try JSONDecoder().decode(MockItemRequest.self, from: JSONEncoder().encode(mock))
        #expect(decoded == mock)
    }
}

struct AppEnvironmentTests {

    @Test func detectsXCTestEnvironment() {
        #expect(AppEnvironment.isRunningTests(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(!AppEnvironment.isRunningTests([:]))
    }

    @Test func isActiveInsideTestRun() {
        // Guards the startup side effects (daemon, system proxy) while tests run.
        #expect(AppEnvironment.isRunningTests())
    }
}

struct WebSocketFrameTests {

    @Test func webSocketTaskUsesRaisedLimitAndAuthHeader() throws {
        let url = try #require(URL(string: "ws://127.0.0.1:8081/ws"))
        let task = ProxyCore.makeWebSocketTask(session: .shared, url: url, token: "abc")
        #expect(task.maximumMessageSize == ProxyCore.webSocketMaximumMessageSize)
        #expect(task.maximumMessageSize > 12 * 1024 * 1024)
        #expect(task.originalRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
    }

    @Test func webSocketReceivesLargeFrameWithoutDisconnect() async throws {
        let frameSize = 2 * 1024 * 1024
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
            connection.send(content: Data(repeating: 0x41, count: frameSize), contentContext: context,
                            isComplete: true, completion: .contentProcessed { _ in })
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue {
                    continuation.yield(port)
                    continuation.finish()
                }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var portValue: UInt16?
        for await port in ready { portValue = port }
        let port = try #require(portValue)

        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws"))
        let task = ProxyCore.makeWebSocketTask(session: .shared, url: url, token: nil)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let message = try await task.receive()
        guard case .data(let data) = message else {
            Issue.record("Expected a binary frame")
            return
        }
        #expect(data.count == frameSize)
        #expect(task.closeCode == .invalid)
    }
}

struct HeaderRedactorTests {

    @Test func masksSensitiveHeadersCaseInsensitively() {
        let out = HeaderRedactor.redact([
            "authorization": "Bearer abc", "Cookie": "sid=1", "SET-COOKIE": "sid=2",
            "Proxy-Authorization": "Basic x", "X-Api-Key": "k", "Accept": "*/*"
        ])
        #expect(out["authorization"] == HeaderRedactor.mask)
        #expect(out["Cookie"] == HeaderRedactor.mask)
        #expect(out["SET-COOKIE"] == HeaderRedactor.mask)
        #expect(out["Proxy-Authorization"] == HeaderRedactor.mask)
        #expect(out["X-Api-Key"] == HeaderRedactor.mask)
        #expect(out["Accept"] == "*/*")
    }

    @Test func revealReturnsOriginalValues() {
        let headers = ["Authorization": "Bearer abc"]
        #expect(HeaderRedactor.redact(headers, reveal: true) == headers)
        #expect(HeaderRedactor.value(for: "Authorization", "Bearer abc", reveal: true) == "Bearer abc")
    }

    @Test func detectsSensitiveHeaders() {
        #expect(HeaderRedactor.hasSensitive(["Cookie": "a"]))
        #expect(!HeaderRedactor.hasSensitive(["Accept": "a"]))
        #expect(!HeaderRedactor.isSensitive("Content-Type"))
    }

    @Test func trimsNamesAndHandlesEmpty() {
        #expect(HeaderRedactor.isSensitive("  X-Auth-Token "))
        #expect(HeaderRedactor.redact([:]).isEmpty)
        #expect(!HeaderRedactor.hasSensitive([:]))
        #expect(HeaderRedactor.redact(["X-Auth-Token": "t"])["X-Auth-Token"] == HeaderRedactor.mask)
    }
}

struct TransactionExporterTests {
    private func makeLog() throws -> ProxyLog {
        let json = """
        {"method":"GET","url":"https://example.com/","request_headers":{"Authorization":"Bearer SECRET","Accept":"*/*"},
         "response_headers":{"Set-Cookie":"sid=SECRET2"},"status_code":200,"timestamp":"2025-04-10T10:00:00Z"}
        """
        return try JSONDecoder().decode(ProxyLog.self, from: Data(json.utf8))
    }

    @Test func masksByDefault() throws {
        let text = TransactionExporter.text(for: try makeLog())
        #expect(!text.contains("SECRET"))
        #expect(text.contains("Authorization: \(HeaderRedactor.mask)"))
        #expect(text.contains("Accept: */*"))
    }

    @Test func revealsWhenRequested() throws {
        let text = TransactionExporter.text(for: try makeLog(), revealSensitive: true)
        #expect(text.contains("Authorization: Bearer SECRET"))
        #expect(text.contains("Set-Cookie: sid=SECRET2"))
    }
}

struct MockJSONWarningTests {
    @Test func validOrEmptyBodyHasNoWarning() {
        #expect(MockModalEditViewModel.jsonWarning(for: "") == nil)
        #expect(MockModalEditViewModel.jsonWarning(for: "  {\"a\": [1, 2]}\n") == nil)
    }

    @Test func invalidBodyWarns() {
        #expect(MockModalEditViewModel.jsonWarning(for: "{\"a\": ") != nil)
        #expect(MockModalEditViewModel.jsonWarning(for: "<html>") != nil)
    }
}

@MainActor
struct SystemProxyManagerTests {
    private static let key = "PacketPeek.systemProxy.enabledServices"

    private func makeDefaults() -> UserDefaults {
        let suite = "SystemProxyManagerTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func keepsFlagWhenAdminCommandFails() {
        let defaults = makeDefaults()
        defaults.set(["Wi-Fi"], forKey: Self.key)
        let manager = SystemProxyManager(defaults: defaults, syncAdminRunner: { _ in 1 })
        #expect(manager.disableSynchronously() == false)
        #expect(defaults.stringArray(forKey: Self.key) == ["Wi-Fi"])
        #expect(manager.hasPendingCleanup)
    }

    @Test func clearsFlagOnlyOnSuccess() {
        let defaults = makeDefaults()
        defaults.set(["Wi-Fi"], forKey: Self.key)
        var script = ""
        let manager = SystemProxyManager(defaults: defaults, syncAdminRunner: { script = $0; return 0 })
        #expect(manager.disableSynchronously())
        #expect(defaults.stringArray(forKey: Self.key) == nil)
        #expect(script.contains("-setwebproxystate \"Wi-Fi\" off"))
    }
}
