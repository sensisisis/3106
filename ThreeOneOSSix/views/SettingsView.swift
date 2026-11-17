import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        language.text("settings.current_version"),
                        value: language.text(
                            appState.isSupported ? "settings.supported" : "settings.unsupported"
                        )
                    )
                    .foregroundStyle(appState.isSupported ? Color.green : Color.red)
                    LabeledContent(
                        language.text("settings.ios_version"),
                        value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))"
                    )
                    LabeledContent(
                        language.text("settings.minimum_ios"),
                        value: "iOS 16.0+"
                    )
                } header: {
                    Text(language.text("common.device"))
                } footer: {
                    Text(language.text("settings.supported_versions_footer"))
                }

                Section(language.text("settings.verified_versions")) {
                    LabeledContent("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
                    LabeledContent("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
                    LabeledContent(
                        "iOS 26",
                        value: "\(ExploitSupportPolicy.verifiedIOS26BadQueryRange) · \(ExploitSupportPolicy.verifiedIOS26WorseQueryRange)"
                    )
                    LabeledContent("iOS 27", value: ExploitSupportPolicy.verifiedIOS27Range)
                }
            }
            .tint(AppTheme.accent)
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
