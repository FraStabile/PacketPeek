//
//  ProxyAppTests.swift
//  ProxyAppTests
//
//  Created by Francesco Stabile on 27/03/25.
//

import Foundation
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
