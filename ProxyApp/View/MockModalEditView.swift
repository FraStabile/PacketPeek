//
//  MockModalEditView.swift
//  ProxyApp
//
//  Created by Francesco Stabile on 15/04/25.
//
import SwiftUI
struct MockModalEditView: View {
    @EnvironmentObject var modalRouter: ModalRouter
    @StateObject var viewModel: MockModalEditViewModel
    init(viewModel: MockModalEditViewModel) {
        self._viewModel = StateObject(wrappedValue: viewModel)
    }
    
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Modifica Mock")
                .font(.title2.bold())
                .padding(.top)
            
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    HStack(alignment: .top) {
                        Text("Metodo:")
                            .font(.subheadline).bold()
                            .frame(width: 80, alignment: .leading)
                        Text(viewModel.log.method)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(alignment: .top) {
                        Text("URL:")
                            .font(.subheadline).bold()
                            .frame(width: 80, alignment: .leading)
                        Text(viewModel.log.url)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(4)
                            .truncationMode(.middle)
                    }
                }
            }
            
            Divider()
            
            VStack(spacing: 16) {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latenza (ms)")
                            .font(.subheadline).bold()
                        TextField("Es: 150", text: $viewModel.latency)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 120)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status Code")
                            .font(.subheadline).bold()
                        TextField("Es: 200", text: $viewModel.statusCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 120)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Risposta JSON")
                        .font(.subheadline).bold()
                    
                    TextEditor(text: $viewModel.response)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 300)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3))
                        )
                        .cornerRadius(8)
                }
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                Button(action: {
                    modalRouter.activeModal = nil
                }) {
                    Label("Annulla", systemImage: "xmark")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button(action: {
                    Task {
                        await viewModel.setupMocks()
                        modalRouter.activeModal = nil
                    }
                }) {
                    Label("Salva", systemImage: "checkmark")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top)
        }
        .padding(24)
    }
}


#Preview {
    MockModalEditView(viewModel: MockModalEditViewModel())
}
