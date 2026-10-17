//
//  ProxyAppTests.swift
//  ProxyAppTests
//
//  Created by Francesco Stabile on 27/03/25.
//

import Foundation
import Network
import Testing
@testable import ProxyApp

struct ProxyAppTests {

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
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
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
