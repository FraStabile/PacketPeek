//
//  MainProvider.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 17/04/25.
//

import Papyrus
import Foundation

/// Central place to construct Papyrus providers. The base URL is loopback by
/// design — the daemon's control plane binds to 127.0.0.1:8081 and always
/// requires the bearer token it writes to `FileManagerUrls.apiTokenURL`.
class MainProvider: ObservableObject {
    static let defaultBaseURL = "http://127.0.0.1:8081"

    let provider: Provider

    init(baseURL: String = MainProvider.defaultBaseURL, auth: PacketPeekAuth = .shared) {
        self.provider = Provider(baseURL: baseURL)
        provider.intercept { request, next in
            var authorized = request
            if let token = await auth.currentToken() {
                authorized.headers["Authorization"] = "Bearer \(token)"
            }
            let response = try await next(authorized)
            // The daemon mints a new token on every start: if ours is stale,
            // re-read it from disk once and retry.
            guard response.statusCode == 401 else { return response }
            await auth.invalidateCache()
            guard let fresh = await auth.currentToken() else { return response }
            var retried = request
            retried.headers["Authorization"] = "Bearer \(fresh)"
            return try await next(retried)
        }
    }

    func mocksService() -> MocksAPI {
        return MocksAPIAPI(provider: provider)
    }
}
