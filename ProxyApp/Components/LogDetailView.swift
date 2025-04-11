//
//  LogDetailView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 11/04/25.
//
import SwiftUI
import Charts
struct LogDetailView: View {
    let log: ProxyLog
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Request to \(log.url)")
                .font(.title3.bold())
                .padding(.bottom, 4)
            
            Divider()
            
            HStack(spacing: 16) {
                requestSection
                Divider()
                responseSection
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
    }
    
    private var requestSection: some View {
        VStack(alignment: .leading) {
            Text("📤 Request")
                .font(.headline)
            TabView {
                summaryView(title: "Request Summary", method: log.method, timestamp: log.timestamp)
                    .tabItem { Label("Summary", systemImage: "doc.text") }
                
                headerView(headers: log.requestHeaders)
                    .tabItem { Label("Headers", systemImage: "list.bullet.rectangle") }
                
                jsonView(body: log.requestBody ?? "")
                    .tabItem { Label("Body", systemImage: "curlybraces") }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var responseSection: some View {
        VStack(alignment: .leading) {
            Text("📥 Response")
                .font(.headline)
            TabView {
                summaryView(title: "Response Summary", statusCode: log.statusCode, duration: Int(log.responseTime))
                    .tabItem { Label("Summary", systemImage: "doc.text") }
                
                headerView(headers: log.responseHeaders)
                    .tabItem { Label("Headers", systemImage: "list.bullet.rectangle") }
                
                jsonView(body: log.responseBody ?? "")
                    .tabItem { Label("Body", systemImage: "curlybraces") }
                
                if let chartData = try? parseChartData(from: log.responseBody ?? "") {
                    chartView(data: chartData)
                        .tabItem { Label("Chart", systemImage: "chart.bar.fill") }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Helpers
    
    private func summaryView(title: String, method: String? = nil, timestamp: Date? = nil, statusCode: Int? = nil, duration: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let method {
                LabeledContent("Method", value: method)
            }
            if let timestamp {
                LabeledContent("Time", value: timestamp.formatted())
            }
            if let statusCode {
                LabeledContent("Status Code", value: "\(statusCode)")
            }
            if let duration {
                LabeledContent("Duration", value: "\(duration) ms")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func headerView(headers: [String: String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key).font(.caption.bold())
                        Text(value).font(.caption).foregroundColor(.gray)
                        Divider()
                    }
                }
            }
            .padding()
        }
    }

    private func jsonView(body: String) -> some View {
        ScrollView {
            TextEditor(text: .constant(formatJSON(body)))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .padding()
        }
    }
    
    private func chartView(data: [(String, Double)]) -> some View {
        Chart(data, id: \.0) { key, value in
            BarMark(x: .value("Key", key), y: .value("Value", value))
        }
        .padding()
    }

    // MARK: - JSON Format Helpers
    
    private func formatJSON(_ string: String) -> String {
        guard
            let data = string.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return string
        }
        return prettyString
    }

    private func parseChartData(from json: String) throws -> [(String, Double)] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Double]
        else {
            throw NSError(domain: "invalid_chart_data", code: 0)
        }
        return obj.sorted { $0.key < $1.key }
    }
}
