import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var patchStore: PatchProjectStore
    @EnvironmentObject private var repositoryStore: PackageRepositoryStore
    @State private var tabNavigation: AppTabNavigationState
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var showAppGroupAlert = false
    @AppStorage("faxAura.didEnterGameMode") private var didEnterGameMode = false
    @StateObject private var scanCoordinator = ScanCoordinator()
    @StateObject private var licenseSession = LicenseSession()

    init() {
#if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--simulate-led-settings") {
            UserDefaults.standard.set(true, forKey: "faxAura.ledLightingEnabled")
            UserDefaults.standard.set(0.56, forKey: "faxAura.ledHue")
            UserDefaults.standard.set(0.72, forKey: "faxAura.ledIntensity")
        }
        if arguments.contains("--simulate-game-mode-selection") {
            UserDefaults.standard.set(false, forKey: "faxAura.didEnterGameMode")
        }
        let initialTab: Int
        if arguments.contains("--simulate-new-tab")
            || arguments.contains("--simulate-sources-tab")
            || arguments.contains("--simulate-installed-tab")
            || arguments.contains("--simulate-patch-tab")
            || arguments.contains("--simulate-features-tab") {
            initialTab = 0
        } else if arguments.contains("--simulate-files-tab") {
            initialTab = 4
        } else if arguments.contains("--simulate-search-tab") {
            initialTab = 5
        } else if arguments.contains("--simulate-cleaner-tab") {
            initialTab = 6
        } else if arguments.contains("--simulate-wallpaper-tab") {
            initialTab = 7
        } else {
            initialTab = AppSection.installed.rawValue
        }
        _tabNavigation = State(initialValue: AppTabNavigationState(selectedTab: initialTab))
        _showSettings = State(
            initialValue: arguments.contains("--simulate-settings")
        )
#else
        _tabNavigation = State(
            initialValue: AppTabNavigationState(selectedTab: AppSection.installed.rawValue)
        )
#endif
    }

    var body: some View {
        Group {
            if showsInstalledContent {
                if showsGameModeSelection {
                    GameModeSelectionView {
                        didEnterGameMode = true
                    }
                } else {
                    Group {
                        if horizontalSizeClass == .regular {
                            regularLayout
                        } else {
                            compactLayout
                        }
                    }
                }
            } else {
                LicenseActivationView(
                    sessionNotice: licenseSession.notice,
                    isRestoring: licenseSession.isRestoring,
                    onActivate: { key in await licenseSession.activate(key) }
                )
            }
        }
        .tint(AppTheme.accent)
        .imageScale(.small)
        .preferredColorScheme(.dark)
        .task(id: scenePhase) {
#if targetEnvironment(simulator)
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--simulate-installed-design")
                || arguments.contains("--simulate-game-mode-selection") { return }
#endif
            await licenseSession.runForegroundSession(for: scenePhase)
        }
        .onChange(of: patchDraftCoordinator.request?.id) { requestID in
            if requestID != nil { tabNavigation.select(AppSection.installed.rawValue) }
        }
        .onChange(of: patchDraftCoordinator.importRequest?.id) { requestID in
            if requestID != nil { tabNavigation.select(AppSection.installed.rawValue) }
        }
        .onChange(of: licenseSession.isAuthorized) { authorized in
            if !authorized {
                showSettings = false
                didEnterGameMode = false
            }
        }
        .onAppear {
            tabNavigation.reconcileSelection(with: featureVisibility)
#if !targetEnvironment(simulator)
            if SandboxAccess.needsWorseQuery, SandboxAccess.appGroup == nil {
                showAppGroupAlert = true
            }
#endif
        }
        .alert(language.text("appgroup.title"), isPresented: $showAppGroupAlert) {
            Button(language.text("common.ok")) {}
        } message: {
            Text(language.text("appgroup.message"))
        }
        .environmentObject(scanCoordinator)
        .sheet(isPresented: $showSettings) { SettingsView(session: licenseSession) }
        .sheet(isPresented: $showLogs) { LogView() }
        .sheet(isPresented: $scanCoordinator.isPresented) {
            ScanProgressSheet()
                .environmentObject(scanCoordinator)
                .environment(\.appLanguage, language)
        }
        .overlay(alignment: .bottom) {
            if scanCoordinator.isRunning && !scanCoordinator.isPresented {
                ScanRunningBanner()
                    .environmentObject(scanCoordinator)
                    .environment(\.appLanguage, language)
            }
        }
        .patchStorePresentation(patchStore)
        .repositoryStorePresentation(repositoryStore, patchStore: patchStore)
    }

    private var showsInstalledContent: Bool {
#if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--simulate-installed-design")
            || arguments.contains("--simulate-game-mode-selection") { return true }
#endif
        return licenseSession.isAuthorized
    }

    private var showsGameModeSelection: Bool {
#if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--simulate-game-mode-selection") { return true }
        if arguments.contains("--simulate-installed-design") { return false }
#endif
        return !didEnterGameMode
    }

    private var compactLayout: some View {
        sectionContent(selectedVisibleSection)
    }

    private var regularLayout: some View {
        sectionContent(selectedVisibleSection)
    }

    @ViewBuilder
    private func sectionContent(_ section: AppSection) -> some View {
        switch section {
        case .home:
            FeatureHubView()
        case .new:
            RepositoryNewView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .sources:
            RepositorySourcesView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .installed:
            PatchProjectsView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs,
                onPatchApplied: { projectID, patchName, ruleID in
                    await licenseSession.recordPatchApplied(
                        projectID: projectID,
                        patchName: patchName,
                        ruleID: ruleID
                    )
                },
                onPatchUndone: { projectID, patchName, ruleID in
                    await licenseSession.recordPatchUndone(
                        projectID: projectID,
                        patchName: patchName,
                        ruleID: ruleID
                    )
                }
            )
        case .files:
            AppDataBrowserView(
                tabSession: filesTabSession,
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .search:
            RepositorySearchView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        case .cleaner:
            CleanerView(onOpenSettings: openSettings)
        case .backup:
            BackupTabView()
        case .wallpapers:
            WallpaperLabView(
                onOpenSettings: openSettings,
                onOpenLogs: openLogs
            )
        }
    }

    private var filesTabSession: Binding<FilesTabSession> {
        Binding(
            get: { tabNavigation.filesTabs },
            set: { tabNavigation.setFilesTabs($0) }
        )
    }

    private var featureVisibility: FeatureVisibility {
        FeatureVisibility(
            selectedSections: [.installed],
            wallpapersSupported: WallpaperFeatureSupportPolicy.isSupported(
                major: AppInfo.versionTuple.major
            ),
            developerModeEnabled: true
        )
    }

    private var selectedVisibleSection: AppSection {
        let selected = AppSection(rawValue: tabNavigation.selectedTab)
        return selected.flatMap {
            featureVisibility.isVisible($0) ? $0 : nil
        } ?? .installed
    }

    private func openSettings() {
        showSettings = true
    }

    private func openLogs() {
        showLogs = true
    }
}

private struct GameModeSelectionView: View {
    let onEnter: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = min(max(geometry.size.width - 36, 0), 484)
            let bannerHeight = min(max(geometry.size.height * 0.18, 112), 145)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 13) {
                    HStack(spacing: 10) {
                        AppLogo(size: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("FAX AURA")
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                .tracking(2.2)
                                .foregroundStyle(.white)
                            Text("PRIVATE ACCESS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.1)
                                .foregroundStyle(.white.opacity(0.54))
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(AppTheme.accent).frame(width: 7, height: 7)
                            Text("ONLINE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }

                    Image("ActivityHeaderArt")
                        .resizable()
                        .scaledToFill()
                        .frame(width: contentWidth, height: bannerHeight)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(AppTheme.accent.opacity(0.82), lineWidth: 1)
                        }
                        .accessibilityLabel("Fax Aura banner")

                    HStack(spacing: 14) {
                        Image("FreeFireReferenceIcon")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(AppTheme.accent.opacity(0.7), lineWidth: 1)
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("FREE FIRE")
                                .font(.system(size: 17, weight: .black, design: .rounded))
                                .tracking(0.8)
                                .foregroundStyle(.white)
                            Text("NORMAL PROFILE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.65))
                        }

                        Spacer(minLength: 4)

                        HStack(spacing: 5) {
                            Text("STABLE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(AppTheme.accent)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .stroke(AppTheme.accent.opacity(0.76), lineWidth: 1)
                    }

                    Text("SELECT GAME MODE")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(AppTheme.accent.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)

                    Button(action: onEnter) {
                        HStack(spacing: 14) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 54, height: 54)
                                .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Normal")
                                    .font(.system(size: 19, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("Stable Free Fire profile")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.76))
                                Text("PROFILE READY / SAFE MODE")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(AppTheme.accent.opacity(0.82))
                            }

                            Spacer(minLength: 4)

                            HStack(spacing: 6) {
                                Text("ENTER")
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 15)
                            .frame(height: 40)
                            .background(AppTheme.accent, in: Capsule())
                        }
                        .padding(15)
                        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(AppTheme.accent.opacity(0.78), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Continue to the Fax Aura console")
                }
                .frame(width: contentWidth)
                .padding(18)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
    }
}
