//
//  LogTableView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 11/04/25.
//
import SwiftUI
struct EmptySelectionView: View {
    var body: some View {
        VStack {
            Text("Select a base path to view logs.")
                .foregroundStyle(.secondary)
        }
    }
}

struct LogTableView: View {
    @ObservedObject var viewModel: HomeViewModel
    @EnvironmentObject var modalRouter: ModalRouter
    @EnvironmentObject var editViewModel: MockModalEditViewModel
    let logs: [ProxyLog]
    @Binding var filter: String

    init(viewModel: HomeViewModel, logs: [ProxyLog], filter: Binding<String>) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.logs = logs
        self._filter = filter
    }

    private var filteredLogs: [ProxyLog] {
        guard !filter.isEmpty else { return logs }
        let needle = filter.lowercased()
        return logs.filter {
            $0.clientIP.lowercased().contains(needle)
            || $0.method.lowercased().contains(needle)
            || $0.url.lowercased().contains(needle)
            || String($0.statusCode).contains(needle)
        }
    }

    var body: some View {
        Table(filteredLogs, selection: $viewModel.selectedLogID) {
            TableColumn("Method") { log in
                MethodBadge(method: log.method)
            }
            .width(min: 60, ideal: 70, max: 80)

            TableColumn("Status") { (log: ProxyLog) in
                StatusCodeBadge(code: log.statusCode)
            }
            .width(min: 60, ideal: 70, max: 80)

            TableColumn("Client") { log in
                Text(log.clientIP)
                    .font(Typography.captionMono)
                    .foregroundStyle(Surface.secondaryText)
            }
            .width(min: 100, ideal: 130, max: 180)

            TableColumn("Time") { (log: ProxyLog) in
                Text(log.timestamp.formatted(date: .omitted, time: .standard))
                    .font(Typography.captionMono)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryText)
            }
            .width(min: 75, ideal: 85, max: 100)

            TableColumn("Duration") { (log: ProxyLog) in
                Text("\(Int(log.responseTime)) ms")
                    .font(Typography.captionMono)
                    .monospacedDigit()
                    .foregroundStyle(durationColor(for: log.responseTime))
            }
            .width(min: 70, ideal: 80, max: 100)

            TableColumn("URL") { log in
                Text(log.url)
                    .font(Typography.bodyMono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(log.url)
            }
        }
        .contextMenu(forSelectionType: ProxyLog.ID.self) { proxyLogs in
            if let selected = logs.first(where: { $0.id == proxyLogs.first }) {
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selected.url, forType: .string)
                }
                Button("Export") {
                    viewModel.exportRequestToTxt(request: selected)
                }
                Button("Mock Request") {
                    editViewModel.setupProxyLog(proxyLog: selected)
                    modalRouter.activeModal = .editMock
                }
            }
        }
    }

    /// Green under 200ms, amber up to 1s, red above. Mirrors how devs read
    /// network panels in browsers.
    private func durationColor(for ms: Double) -> Color {
        switch ms {
        case ..<200:    return Color(red: 0.18, green: 0.74, blue: 0.45)
        case ..<1000:   return Color(red: 0.95, green: 0.62, blue: 0.10)
        default:        return Color(red: 0.92, green: 0.32, blue: 0.32)
        }
    }
}
