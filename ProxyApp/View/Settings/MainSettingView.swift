import SwiftUI
import SwiftDependency
struct MainSettingView: View {
    let settings: [any SettingsItemProtocol] = [
        GeneralSettings(),
        ThemeSettings()
    ]
    
    @State private var selectedID: UUID?
    @InjectProps private var settingsManager: SettingsManagerProtocol
    var body: some View {
        HSplitView {
            sidebar
                .background(
                    LinearGradient(colors: [Color(NSColor.windowBackgroundColor), .gray.opacity(0.05)],
                                   startPoint: .top,
                                   endPoint: .bottom)
                )
                .frame(maxWidth: 200)
            rightContent
                .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            _ = settingsManager.loadSettings()
        }
    }

    var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(settings, id: \.id) { item in
                    sidebarItem(for: item)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
        }
        .frame(minWidth: 220)
        .background(Color(.windowBackgroundColor).opacity(0.95))
    }

    private func sidebarItem(for item: any SettingsItemProtocol) -> some View {
        @State var isHovering = false

        return HStack(spacing: 12) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selectedID == item.id ? Color.accentColor : .primary)
            }
            Text(item.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selectedID == item.id ? Color.accentColor.opacity(0.2) :
                      isHovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            selectedID = item.id
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }


    var rightContent: some View {
        Group {
            if let selected = settings.first(where: { $0.id == selectedID }) {
                VStack {
                    AnyView(selected.content())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Spacer()
                        Button("Save") {
                            settingsManager.saveSettings(settingsManager.getCurrentSettings())
                        }
                        .buttonStyle(BorderedProminentButtonStyle())
                        .padding()
                    }
                    
                }
            } else {
                VStack {
                    Image(systemName: "gear")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Select a setting")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }
}

#Preview {
    MainSettingView()
}
