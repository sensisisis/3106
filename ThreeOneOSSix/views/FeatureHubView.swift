import SwiftUI

struct FeatureHubView: View {
    @Environment(\.appLanguage) private var language

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AuraConsoleHeader(
                        title: language.text("tab.compatibility"),
                        subtitle: "SUPPORTED IOS / 3106",
                        systemImage: "checkmark.seal.fill"
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
                }
                .listRowBackground(Color.clear)

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
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .navigationTitle(language.text("tab.compatibility"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
    }
}
