import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState

    @ObservedObject var session: LicenseSession
    @AppStorage("faxAura.ledLightingEnabled") private var ledLightingEnabled = false
    @State private var showsActivation = false

    init(session: LicenseSession) {
        self.session = session
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    appInfoCard

                    VStack(alignment: .leading, spacing: 11) {
                        Text(language.text("common.device"))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.horizontal, 4)

                        deviceCard
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        Text("SETTINGS")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.horizontal, 4)

                        SettingsValueRow(
                            label: language.text("settings.current_version"),
                            value: language.text(
                                appState.isSupported
                                    ? "settings.supported"
                                    : "settings.unsupported"
                            ),
                            valueColor: appState.isSupported ? .green : .red
                        )
                        .settingsGraphiteCard()

                        compatibilityDisclosure
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        Text("ACCESS CONTROL")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.horizontal, 4)

                        AccessControlCard(session: session) {
                            showsActivation = true
                        }
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        Text("AURA RGB DARK")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.horizontal, 4)

                        Toggle(isOn: $ledLightingEnabled) {
                            Text("Enable LED lighting")
                                .font(.system(size: 17, weight: .regular, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .tint(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 62)
                        .settingsGraphiteCard()

                        Text("Adds a customizable LED accent to the Fax Aura console.\nText remains white for readability.")
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background(SettingsPalette.background.ignoresSafeArea())
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: { settingsToolbar })
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsActivation) {
            LicenseActivationView(
                sessionNotice: session.notice,
                onActivate: { key in
                    await activate(key)
                }
            )
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                dismiss()
            } label: {
                Text(language.text("common.done"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 17)
                    .frame(height: 38)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var appInfoCard: some View {
        HStack(spacing: 15) {
            AppLogo(size: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text("Fax Aura")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Version \(AppInfo.appVersion)")
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .frame(minHeight: 112)
        .settingsGraphiteCard(cornerRadius: 26)
    }

    private var deviceCard: some View {
        VStack(spacing: 0) {
            SettingsValueRow(
                label: "Hardware model",
                value: AppInfo.machineName,
                valueColor: .white.opacity(0.58)
            )

            Divider()
                .overlay(Color.white.opacity(0.13))
                .padding(.horizontal, 18)

            SettingsValueRow(
                label: language.text("settings.ios_version"),
                value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))",
                valueColor: .white.opacity(0.58)
            )
        }
        .settingsGraphiteCard(cornerRadius: 26)
    }

    private var compatibilityDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                compatibilityRow("iOS minimum", "16.0+")
                compatibilityRow("iOS 17", ExploitSupportPolicy.verifiedIOS17Range)
                compatibilityRow("iOS 18", ExploitSupportPolicy.verifiedIOS18Range)
                compatibilityRow(
                    "iOS 26",
                    "\(ExploitSupportPolicy.verifiedIOS26BadQueryRange) · \(ExploitSupportPolicy.verifiedIOS26WorseQueryRange)"
                )
                compatibilityRow("iOS 27", ExploitSupportPolicy.verifiedIOS27Range)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Text(language.text("settings.verified_versions"))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
            }
        }
        .font(.system(size: 13, weight: .regular, design: .rounded))
        .tint(.white.opacity(0.72))
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .settingsGraphiteCard(cornerRadius: 20)
    }

    private func compatibilityRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.white.opacity(0.68))
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white.opacity(0.48))
        }
        .font(.system(size: 12, weight: .regular, design: .monospaced))
    }

    private func activate(_ key: String) async -> LicenseActivationResult {
        let result = await session.activate(key)
        if case .success = result {
            await MainActor.run {
                showsActivation = false
            }
        }
        return result
    }
}

private struct SettingsValueRow: View {
    let label: String
    let value: String
    let valueColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(.white)

            Spacer(minLength: 10)

            Text(value)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 62)
    }
}

private struct AccessControlCard: View {
    @ObservedObject var session: LicenseSession
    let onManage: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = accessState(at: context.date)

            VStack(alignment: .leading, spacing: 19) {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.19))
                        Circle()
                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        Image(systemName: "key.fill")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("KEY CONTROL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.3)
                            .foregroundStyle(.white.opacity(0.50))

                        HStack(spacing: 8) {
                            Text(state.title)
                                .font(.system(size: 20, weight: .black, design: .rounded))
                                .tracking(0.4)
                                .foregroundStyle(.white)
                                .minimumScaleFactor(0.75)

                            Circle()
                                .fill(state.accent)
                                .frame(width: 8, height: 8)
                                .shadow(color: state.accent.opacity(0.85), radius: 7)
                        }
                    }

                    Spacer(minLength: 6)

                    Button(action: onManage) {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("MANAGE")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 13)
                        .frame(height: 42)
                        .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Manage license")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("TIME REMAINING")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.50))

                    Text(timeRemaining(for: state, at: context.date))
                        .font(.system(size: 28, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.72)
                }

                HStack(spacing: 12) {
                    Capsule()
                        .fill(state.accent.opacity(0.92))
                        .frame(maxWidth: .infinity)
                        .frame(height: 5)
                        .shadow(color: state.accent.opacity(0.35), radius: 5)

                    Text(state.indicatorLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(state.accent)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Session status")
                .accessibilityValue(state.title)
            }
            .padding(20)
            .background {
                ZStack {
                    Color.black.opacity(0.94)
                    RadialGradient(
                        colors: [state.accent.opacity(0.16), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 280
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.66), lineWidth: 1)
            }
            .shadow(color: state.accent.opacity(0.15), radius: 22, y: 9)
        }
    }

    @MainActor
    private func accessState(at date: Date) -> AccessSessionState {
        if session.notice == "license.error.paused" {
            return .paused
        }

        guard session.isAuthorized else {
            return .expired
        }

        if session.isPermanentLicense {
            return .active
        }

        guard let expirationDate = session.expirationDate else {
            return .expired
        }

        return expirationDate > date ? .active : .expired
    }

    @MainActor
    private func timeRemaining(for state: AccessSessionState, at date: Date) -> String {
        switch state {
        case .active, .paused:
            if session.isPermanentLicense {
                return "NO EXPIRY"
            }

            guard session.hasStoredLicense, let expirationDate = session.expirationDate else {
                return "UNAVAILABLE"
            }

            return remainingText(until: expirationDate, at: date)

        case .expired:
            if let expirationDate = session.expirationDate, expirationDate <= date {
                return "EXPIRED"
            }
            return session.hasStoredLicense ? "SESSION NOT ACTIVE" : "NO ACTIVE SESSION"
        }
    }

    private func remainingText(until expirationDate: Date, at date: Date) -> String {
        let seconds = max(0, Int(expirationDate.timeIntervalSince(date)))
        guard seconds > 0 else { return "EXPIRED" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if days > 0 {
            return "\(days)d \(String(format: "%02dh", hours))"
        }
        if hours > 0 {
            return "\(hours)h \(String(format: "%02dm", minutes))"
        }
        if minutes > 0 {
            return "\(minutes)m \(String(format: "%02ds", remainingSeconds))"
        }
        return "\(max(1, remainingSeconds))s"
    }
}

private enum AccessSessionState {
    case active
    case paused
    case expired

    var title: String {
        switch self {
        case .active: return "SESSION ACTIVE"
        case .paused: return "SESSION PAUSED"
        case .expired: return "SESSION EXPIRED"
        }
    }

    var indicatorLabel: String {
        switch self {
        case .active: return "ACTIVE"
        case .paused: return "PAUSED"
        case .expired: return "EXPIRED"
        }
    }

    var accent: Color {
        switch self {
        case .active: return Color(red: 0.34, green: 0.92, blue: 0.58)
        case .paused: return Color(red: 1.0, green: 0.67, blue: 0.23)
        case .expired: return Color(red: 1.0, green: 0.34, blue: 0.38)
        }
    }
}

private enum SettingsPalette {
    static let background = Color.black
    static let graphite = Color(red: 0.145, green: 0.145, blue: 0.16)
}

private extension View {
    func settingsGraphiteCard(cornerRadius: CGFloat = 24) -> some View {
        background(
            SettingsPalette.graphite,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
