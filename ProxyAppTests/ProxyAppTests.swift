//
//  ProxyAppTests.swift
//  ProxyAppTests
//
//  Created by Francesco Stabile on 27/03/25.
//

import Foundation
import Testing
@testable import ProxyApp

struct ProxyAppTests {

    @Test func webSocketAcceptsFramesLargerThanOneMiB() {
        #expect(ProxyCore.webSocketMaximumMessageSize > 1024 * 1024)
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8081/ws")!)
        task.maximumMessageSize = ProxyCore.webSocketMaximumMessageSize
        #expect(task.maximumMessageSize == 16 * 1024 * 1024)
    }

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}
