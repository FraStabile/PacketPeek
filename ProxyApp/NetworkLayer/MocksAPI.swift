//
//  MainProvider.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 17/04/25.
//

import Papyrus

@API
protocol MocksAPI {
    @GET("/api/mocks")
    func getMocks() async throws -> [MockItemRequest]
    
    @POST("/api/mocks")
    @Headers(["Content-Type": "application/json"])
    func updateMock(_ mock: Body<MockItemRequest>) async throws
    
    @GET("/api/mocks/:id")
    func deleteMock(id: String) async throws
    
    @GET("/api/apps")
    func getApps() async throws -> [AuthorizedApp]
    
    
    @POST("/api/apps")
    func setApps(_ apps: Body<AuthorizedApp>) async throws
    
}
