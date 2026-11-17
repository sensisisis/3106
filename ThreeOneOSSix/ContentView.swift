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
    @AppStorage("faxAura.ledLightingEnabled") private var ledLightingEnabled = false
    @StateObject private var scanCoordinator = ScanCoordinator()
    @StateObject private var licenseSession = LicenseSession()

    init() {
#if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
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
                Group {
                    if horizontalSizeClass == .regular {
                        regularLayout
                    } else {
                        compactLayout
                    }
                }
            } else {
                LicenseActivationView(
                    sessionNotice: licenseSession.notice,
                    onActivate: { key in await licenseSession.activate(key) }
                )
            }
        }
        .tint(AppTheme.accent)
        .imageScale(.small)
        .preferredColorScheme(.dark)
        .task(id: scenePhase) {
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--simulate-installed-design") { return }
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
            if !authorized { showSettings = false }
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
        .overlay {
            if ledLightingEnabled && showsInstalledContent {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [.cyan.opacity(0.55), .purple.opacity(0.45), .pink.opacity(0.50)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                    .shadow(color: .purple.opacity(0.20), radius: 12)
                    .padding(5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
        if ProcessInfo.processInfo.arguments.contains("--simulate-installed-design") { return true }
#endif
        return licenseSession.isAuthorized
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
            PatchProjectsView(onOpenSettings: openSettings, onOpenLogs: openLogs)
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
