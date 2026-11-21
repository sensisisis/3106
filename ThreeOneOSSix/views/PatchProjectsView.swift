import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum PatchPackagePickerPolicy {
    // Export uses the new .3106 extension; .3105 stays importable so existing
    // patch repositories keep working.
    static let packageType = UTType(filenameExtension: "3106")
        ?? UTType(filenameExtension: "3105")
        ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
    static let copiesSelectedDocument = true
}

private enum WallpaperPackagePickerPolicy {
    static let packageType = UTType(filenameExtension: "tendies") ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
}

struct PatchProjectsView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var draftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var store: PatchProjectStore
    @ObservedObject private var appLog = AppLog.shared
    @AppStorage(FeatureVisibility.cleanerStorageKey) private var cleanerEnabled = true
    @State private var showCreate = false
    @State private var showImporter = false
    @State private var showWallpaperImporter = false
    @State private var showCleaner = false
    @State private var wallpaperPackages: [WallpaperStagedPackage] = []
    @State private var wallpaperImportFeedback: WallpaperImportFeedback?
    @State private var wallpaperPendingDeletion: WallpaperStagedPackage?
    @State private var isImportingWallpapers = false
    @State private var isModuleOperationInProgress = false
    @State private var showSimulatedWallpaperDetail = false
    @State private var simulatedWallpaperDetailGate = OneShotPresentationGate()
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void
    let onPatchApplied: @MainActor (UUID, String, UUID) async -> Void
    let onPatchUndone: @MainActor (UUID, String, UUID) async -> Void

    private var isDesignPreview: Bool {
#if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--simulate-installed-design")
#else
        return false
#endif
    }

    // Visual fixtures never enter the device build or the user's library.
    private var installedItems: [PatchLibraryItem] {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-installed-design") {
            return Self.designPreviewItems
        }
#endif
        return store.items
    }

#if targetEnvironment(simulator)
    private static let designPreviewItems: [PatchLibraryItem] = {
        let names = ProcessInfo.processInfo.arguments.contains("--simulate-installed-single")
            ? ["Hs Pescoço+Antena"]
            : ["Aim 60%", "Headtricking 70%", "Aim 100%", "Headtricking 100%"]
        return names.map { name in
            let project = PatchProject(name: name, rules: [
                PatchRule(bundleID: "com.example.visual-preview", relativePath: "preview.txt",
                          replacementFilename: "preview.txt", replacementData: Data())
            ])
            return PatchLibraryItem(
                summary: PatchPackageSummary(packageID: project.id, schemaVersion: 2,
                                             isPasswordProtected: false, keyFingerprint: Data()),
                project: project, contentKey: nil,
                packageURL: URL(fileURLWithPath: "/visual-preview/\(project.id).3106"),
                isAuthorCopy: true, origin: nil
            )
        }
    }()
#endif

    private var hasLocalContent: Bool {
        !installedItems.isEmpty
    }

    private var totalRuleCount: Int {
        installedItems.reduce(0) { count, item in
            guard item.canInspectContents, let project = item.project else { return count }
            return count + project.rules.count
        }
    }

    private var activeRuleCount: Int {
        installedItems.reduce(0) { count, item in
            guard item.canInspectContents, let project = item.project else { return count }
            if DevicePatchService.latestReceipt(projectID: item.id) != nil {
                return count + project.rules.count
            }
            return count + project.rules.filter {
                DevicePatchService.isRuleApplied(projectID: item.id, ruleID: $0.id)
            }.count
        }
    }

    private var consoleBrandHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AURA CONSOLE")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(AppTheme.accent)
                Text("PATCH CONTROL / \(language.text("installed.online"))")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("V\(AppInfo.appVersion)")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.52), lineWidth: 0.8))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            HStack(spacing: 5) {
                Rectangle().fill(AppTheme.accent.opacity(0.92)).frame(width: 26, height: 1)
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1)
            }
            .padding(.horizontal, 14)
            .offset(y: 3)
        }
    }

    private var faxAuraBanner: some View {
        ZStack {
            Color.black
            Image("ActivityHeaderArt")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.04), Color.black.opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.65), radius: 8, y: 3)
        .accessibilityLabel("Fax Aura")
    }

    private var activityCard: some View {
        Button(action: onOpenLogs) {
            HStack(spacing: 9) {
                activityLogIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text("Registro de actividad")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text(isModuleOperationInProgress
                         ? "Actualizando función"
                         : activeRuleCount > 0
                            ? "\(activeRuleCount) funciones activas"
                            : "Sistema listo — esperando funciones")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(activityDetail)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.90))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Circle()
                    .fill(Color.green)
                    .frame(width: 9, height: 9)
                    .shadow(color: .green, radius: 4)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color(white: 0.10), Color(white: 0.065), Color(white: 0.045)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.accent.opacity(0.48), lineWidth: 0.9)
            }
            .overlay { activityOrbitMotion }
            .shadow(color: .black.opacity(0.72), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private var activityDetail: String {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-installed-design") {
            return "Sin operaciones recientes"
        }
#endif
        return appLog.entries.last ?? "Sin operaciones recientes"
    }

    private var activityOrbitMotion: some View {
        NativeActivitySilverOrbit(reduceMotion: orbitUsesReducedMotion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var orbitUsesReducedMotion: Bool {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-orbit-reduce-motion") {
            return true
        }
#endif
        return reduceMotion
    }

    private var activityLogIcon: some View {
        ZStack {
            Circle()
                .fill(AppTheme.accent.opacity(0.28))
                .shadow(color: AppTheme.accent.opacity(0.18), radius: 5)
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
        }
        .frame(width: 34, height: 34)
    }

    private var moduleStatusPanel: some View {
        HStack(spacing: 0) {
            statusMetric(
                symbol: "square.grid.2x2",
                value: "\(totalRuleCount)",
                label: language.text("installed.modules")
            )
            statusDivider
            statusMetric(
                symbol: "antenna.radiowaves.left.and.right",
                value: "LIVE",
                label: "LINK"
            )
            statusDivider
            statusMetric(
                symbol: "checkmark.shield",
                value: language.text("installed.safe"),
                label: language.text("installed.mode")
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.095), Color.white.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.30), lineWidth: 0.8))
        .shadow(color: .white.opacity(0.05), radius: 8, y: 2)
    }

    private var statusDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.20))
            .frame(width: 1, height: 24)
    }

    private func statusMetric(symbol: String, value: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppTheme.accent.opacity(0.9))
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(AppTheme.accent)
                Text(label.uppercased())
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var quickActions: some View {
        HStack(spacing: 7) {
            Button {
                store.reload()
            } label: {
                quickActionLabel("installed.reload", symbol: "arrow.clockwise")
            }
            .disabled(store.isBusy || isModuleOperationInProgress)

            Menu {
                Button {
                    showImporter = true
                } label: {
                    Label(language.text("patch.import"), systemImage: "square.and.arrow.down")
                }
                Button {
                    showCreate = true
                } label: {
                    Label(language.text("patch.new"), systemImage: "doc.badge.plus")
                }
            } label: {
                quickActionLabel("installed.import", symbol: "square.and.arrow.down")
            }
            .disabled(store.isBusy || isModuleOperationInProgress)

            Button(action: onOpenSettings) {
                quickActionLabel("settings.title", symbol: "gearshape")
            }
        }
    }

    private func quickActionLabel(_ key: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.accent)
            Text(language.text(key).uppercased())
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 43)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.14), Color.white.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.30), lineWidth: 0.8)
                Rectangle()
                    .fill(AppTheme.accent.opacity(0.90))
                    .frame(width: 18, height: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 10)
                    .padding(.top, 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var functionsHeading: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(AppTheme.accent)
                .frame(width: 4, height: 23)
            VStack(alignment: .leading, spacing: 1) {
                Text("FUNCTIONS")
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .foregroundStyle(AppTheme.accent)
                Text("PATCH MODULES / AVAILABLE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Text("\(activeRuleCount) activos").foregroundStyle(.white)
                Text("•").foregroundStyle(.secondary)
                Text("\(totalRuleCount) total").foregroundStyle(.white)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .overlay(Capsule().stroke(.white.opacity(0.48), lineWidth: 1))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
    }

    private func installedTab(reselect: @escaping () -> Void) -> some View {
        // Reproduce the reference's floating tab on every supported iOS version,
        // rather than changing its shape with the SDK's native TabView style.
        Button(action: reselect) {
            VStack(spacing: 3) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 25, weight: .medium))
                Text(language.text("tab.installed"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color(red: 0.95, green: 0.12, blue: 0.16))
            .frame(width: 100, height: 60)
            .background(Color(white: 0.24), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(white: 0.10), lineWidth: 3))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.8), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isSelected)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    init(
        onOpenSettings: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {},
        onPatchApplied: @escaping @MainActor (UUID, String, UUID) async -> Void = { _, _, _ in },
        onPatchUndone: @escaping @MainActor (UUID, String, UUID) async -> Void = { _, _, _ in }
    ) {
        self.onOpenSettings = onOpenSettings
        self.onOpenLogs = onOpenLogs
        self.onPatchApplied = onPatchApplied
        self.onPatchUndone = onPatchUndone
#if targetEnvironment(simulator)
        _showCreate = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("--simulate-patch-editor")
        )
#endif
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                VStack(spacing: 0) {
                    Text(language.text("tab.installed"))
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 31)
                    consoleBrandHeader
                    faxAuraBanner
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                    activityCard
                        .padding(.horizontal, 12)
                        .padding(.top, 7)
                    moduleStatusPanel
                        .padding(.horizontal, 12)
                        .padding(.top, 5)
                    quickActions
                        .padding(.horizontal, 12)
                        .padding(.top, 5)
                    functionsHeading
                        .padding(.horizontal, 12)
                        .padding(.top, 7)
                        .padding(.bottom, 1)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            Color.clear.frame(height: 0).id("installed-list-top")
                            if !hasLocalContent && store.isBusy {
                                loadingState
                            } else if !hasLocalContent {
                                emptyState
                            } else {
                                ForEach(installedItems) { item in
                                    itemRow(item)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .background(
                        LinearGradient(colors: [.black, Color(white: 0.018)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    installedTab {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            scroll.scrollTo("installed-list-top", anchor: .top)
                        }
                    }
                }
            }
            .background(
                ZStack {
                    Color.black
                    RadialGradient(colors: [.white.opacity(0.05), .clear],
                                   center: .topTrailing, startRadius: 10, endRadius: 430)
                    LinearGradient(colors: [.clear, .white.opacity(0.018), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .ignoresSafeArea()
            )
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showImporter) {
                FileDocumentPicker(
                    allowedContentTypes: PatchPackagePickerPolicy.allowedContentTypes,
                    copiesSelectedDocument: PatchPackagePickerPolicy.copiesSelectedDocument,
                    allowsMultipleSelection: false,
                    onSelection: { result in
                        showImporter = false
                        if case .success(let urls) = result, let url = urls.first {
                            store.importPackage(at: url)
                        }
                    },
                    onCancel: {
                        showImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showCreate) {
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false
                ) { project, password in
                    store.create(project: project, password: password)
                }
            }
            .sheet(item: $draftCoordinator.request) { request in
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false,
                    initialDraft: request.draft
                ) { project, password in
                    store.create(project: project, password: password)
                    draftCoordinator.clear()
                }
            }
            .onAppear {
                consumeExternalImport()
#if targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains(
                    "--simulate-wallpaper-detail"
                ), !wallpaperPackages.isEmpty,
                   simulatedWallpaperDetailGate.claim() {
                    DispatchQueue.main.async {
                        showSimulatedWallpaperDetail = true
                    }
                }
#endif
            }
            .navigationDestination(isPresented: $showSimulatedWallpaperDetail) {
                if let package = wallpaperPackages.first {
                    InstalledWallpaperPackageDetailView(
                        package: package,
                        onApplied: reloadWallpaperPackages
                    )
                }
            }
            .onChange(of: draftCoordinator.importRequest?.id) { _ in
                consumeExternalImport()
            }
        }
    }

    private func consumeExternalImport() {
        guard let request = draftCoordinator.importRequest else { return }
        draftCoordinator.clearImport()
        store.importPackage(from: request.source)
    }

    private func wallpaperRow(_ package: WallpaperStagedPackage) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: wallpaperSymbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                InstalledContentKindBadge(kind: .wallpaper, language: language)
                Text(language.text(
                    "wallpaper.package_summary",
                    Int64(package.payload.descriptors.count),
                    ByteCountFormatter.string(
                        fromByteCount: package.payload.totalBytes,
                        countStyle: .file
                    )
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.12), Color.white.opacity(0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
        }
    }

    private var cleanerRow: some View {
        Button {
            showCleaner = true
        } label: {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("tab.cleaner"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(language.text("repository.cleaner_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.045)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private var wallpaperSymbol: String {
        if #available(iOS 18.0, *) {
            return "photo.on.rectangle.angled.fill"
        }
        return "photo.fill.on.rectangle.fill"
    }

    private func reloadWallpaperPackages() {
        wallpaperPackages = WallpaperPackageStore.packages()
    }

    private func deleteWallpaperPackage(_ package: WallpaperStagedPackage) {
        do {
            try WallpaperPackageStore.delete(package)
            reloadWallpaperPackages()
        } catch {
            wallpaperImportFeedback = WallpaperImportFeedback(
                titleKey: "wallpaper.operation_failed",
                message: wallpaperErrorMessage(error)
            )
        }
    }

    private func importWallpaperPackages(_ urls: [URL]) {
        guard !isImportingWallpapers else { return }
        isImportingWallpapers = true
        DispatchQueue.global(qos: .userInitiated).async {
            var imported = 0
            var failures: [String] = []
            for url in urls {
                do {
                    _ = try WallpaperPackageStore.importPackage(from: url)
                    imported += 1
                    log("wallpaper: staged \(url.lastPathComponent)")
                } catch {
                    failures.append(
                        "\(url.lastPathComponent): \(wallpaperErrorMessage(error))"
                    )
                    log("wallpaper: import rejected \(url.lastPathComponent)")
                }
            }
            DispatchQueue.main.async {
                isImportingWallpapers = false
                reloadWallpaperPackages()
                wallpaperImportFeedback = WallpaperImportFeedback(
                    titleKey: failures.isEmpty
                        ? "wallpaper.import_done_title"
                        : "wallpaper.import_result_title",
                    message: failures.isEmpty
                        ? language.text(
                            "wallpaper.import_done_message",
                            Int64(imported)
                        )
                        : failures.joined(separator: "\n")
                )
            }
        }
    }

    private func wallpaperErrorMessage(_ error: Error) -> String {
        if let wallpaperError = error as? WallpaperLabError {
            return language.text(wallpaperError.localizationKey)
        }
        return language.text("wallpaper.error.unknown")
    }

    @ViewBuilder
    private func itemRow(_ item: PatchLibraryItem) -> some View {
        if item.isLocked {
            Button { store.requestUnlock(for: item) } label: {
                projectCard(item)
            }
            .buttonStyle(.plain)
            .contextMenu { deleteMenu(item) }
        } else if let project = item.project,
                  item.canInspectContents,
                  !project.rules.isEmpty {
            ForEach(project.rules) { rule in
                moduleFunctionRow(item: item, project: project, rule: rule)
                    .contextMenu { deleteMenu(item) }
            }
        } else {
            projectCard(item)
                .contextMenu { deleteMenu(item) }
        }
    }

    private func moduleFunctionRow(
        item: PatchLibraryItem,
        project: PatchProject,
        rule: PatchRule
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Image("OptionCardArt")
                        .resizable()
                        .scaledToFill()
                    LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.74)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 3)
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(0.84), lineWidth: 0.9))
                .shadow(color: .white.opacity(0.18), radius: 5)
                .accessibilityHidden(true)
                Text(project.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)

            PatchModuleToggle(
                item: item,
                project: project,
                rule: rule,
                storeIsBusy: store.isBusy || isDesignPreview,
                appIsBusy: $isModuleOperationInProgress,
                onUpdate: store.reload,
                onPatchApplied: onPatchApplied,
                onPatchUndone: onPatchUndone
            )
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.105), Color(white: 0.028)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.accent.opacity(0.42), lineWidth: 0.8)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [AppTheme.accent.opacity(0.16), .clear, AppTheme.accent.opacity(0.38)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                HStack {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AppTheme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 9)
                    Spacer()
                }
            }
        }
        .shadow(color: .black.opacity(0.72), radius: 6, y: 2)
    }

    private func projectCard(_ item: PatchLibraryItem) -> some View {
        PatchProjectRow(item: item, language: language)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func deleteMenu(_ item: PatchLibraryItem) -> some View {
        if !item.isBundled {
            Button(role: .destructive) {
                guard !isModuleOperationInProgress else { return }
                store.delete(item)
            } label: {
                Label(language.text("common.delete"), systemImage: "trash")
            }
            .disabled(isModuleOperationInProgress)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text("installed.empty_title"))
                .font(.headline)
            Text(language.text("installed.empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(language.text("patch.new")) { showCreate = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(language.text("installed.loading"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

}

private struct WallpaperImportFeedback: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

private struct PatchProjectRow: View {
    let item: PatchLibraryItem
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: item.isLocked ? "lock.doc.fill" : "shippingbox.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.project?.name ?? language.text("patch.locked_project"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer()
            if item.summary.isPasswordProtected {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(language.text("patch.password_protected"))
            }
            if item.project?.isPrivate == true {
                Image(systemName: "eye.slash.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel(language.text("patch.private"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.12), Color.white.opacity(0.045), Color.black.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.30), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
    }
}

private struct PatchModuleToggle: View {
    @Environment(\.appLanguage) private var language
    let item: PatchLibraryItem
    let project: PatchProject
    let rule: PatchRule
    let storeIsBusy: Bool
    @Binding var appIsBusy: Bool
    let onUpdate: () -> Void
    let onPatchApplied: @MainActor (UUID, String, UUID) async -> Void
    let onPatchUndone: @MainActor (UUID, String, UUID) async -> Void

    @State private var showChangedRestoreConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var isWorking = false
    @State private var pendingActiveState: Bool?
    @State private var changedPaths: [String] = []
    @State private var alert: PatchStoreAlert?

    private var legacyReceipt: PatchTransactionReceipt? {
        DevicePatchService.latestReceipt(projectID: item.id)
    }

    private var isPersistentlyActive: Bool {
        legacyReceipt != nil || DevicePatchService.isRuleApplied(
            projectID: project.id,
            ruleID: rule.id
        )
    }

    private var isActive: Bool {
        pendingActiveState ?? isPersistentlyActive
    }

    private var hasUnclassifiedTransaction: Bool {
        legacyReceipt == nil
            && project.rules.allSatisfy {
                !DevicePatchService.isRuleApplied(projectID: project.id, ruleID: $0.id)
            }
            && DevicePatchService.hasActiveTransactions(projectID: project.id)
    }

    private var changedRestoreMessage: String {
        guard !project.isPrivate || item.isAuthorCopy else {
            return language.text("patch.restore_changed_private_message", Int64(changedPaths.count))
        }
        let paths = changedPaths.prefix(5).joined(separator: "\n")
            + (changedPaths.count > 5 ? "\n…" : "")
        return language.text(
            "patch.restore_changed_message",
            Int64(changedPaths.count),
            paths
        )
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(language.text(hasUnclassifiedTransaction
                ? "patch.module_restore_unavailable"
                : isActive ? "patch.module_running" : "patch.module_ready"))
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(hasUnclassifiedTransaction
                    ? Color.orange
                    : isActive ? Color.green : Color.white.opacity(0.62))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(hasUnclassifiedTransaction
                    ? Color.orange.opacity(0.15)
                    : isActive ? Color.green.opacity(0.15) : Color.white.opacity(0.08), in: Capsule())
                .lineLimit(1)

            Text(language.text(hasUnclassifiedTransaction
                ? "patch.module_undo_unavailable"
                : isActive ? "patch.module_undo_action" : "patch.module_apply_action"))
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(isActive ? 0.88 : 0.82))
                .lineLimit(1)

            Button {
                requestToggle(enabled: !isActive)
            } label: {
                HStack(spacing: 5) {
                    Text(hasUnclassifiedTransaction ? "—" : isActive ? "ON" : "OFF")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                    Circle()
                        .fill(isActive ? Color.black : Color.white)
                        .frame(width: 15, height: 15)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(isActive ? 0.14 : 0.82), lineWidth: 0.6)
                        }
                        .shadow(color: .black.opacity(0.38), radius: 1.5, y: 1)
                }
                .foregroundStyle(isActive ? Color.black : Color.white)
                .padding(.horizontal, 7)
                .frame(width: 58, height: 28)
                    .background(isActive ? AppTheme.accent : Color.white.opacity(0.10), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                isActive ? AppTheme.accent.opacity(0.96) : Color.white.opacity(0.38),
                                lineWidth: 1
                            )
                    }
                .shadow(
                    color: isActive ? AppTheme.accent.opacity(0.32) : .clear,
                    radius: 7
                )
                .animation(.easeInOut(duration: 0.16), value: isActive)
            }
            .buttonStyle(.plain)
            .disabled(
                appIsBusy || storeIsBusy || legacyReceipt != nil || hasUnclassifiedTransaction
            )
            .accessibilityLabel("\(project.name), \(hasUnclassifiedTransaction ? language.text("patch.module_restore_unavailable") : isActive ? "ON" : "OFF")")
            .accessibilityValue(language.text(hasUnclassifiedTransaction
                ? "patch.module_restore_unavailable"
                : isActive ? "patch.module_running" : "patch.module_ready"))
        }
        .frame(width: 64)
        .confirmationDialog(
            language.text("patch.restore_confirm_title"),
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.restore"), role: .destructive) {
                prepareRestore()
            }
            Button(language.text("common.cancel"), role: .cancel) { cancelPendingAction() }
        } message: {
            Text(language.text("patch.restore_confirm_message"))
        }
        .confirmationDialog(
            language.text("patch.restore_changed_title"),
            isPresented: $showChangedRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.restore_changed_action"), role: .destructive) {
                restore(allowChangedTargets: true)
            }
            Button(language.text("common.cancel"), role: .cancel) { cancelPendingAction() }
        } message: {
            Text(changedRestoreMessage)
        }
        .onChange(of: showRestoreConfirmation) { showing in
            if !showing { releaseBusyIfIdle() }
        }
        .onChange(of: isWorking) { working in
            if !working { releaseBusyIfIdle() }
        }
        .onChange(of: showChangedRestoreConfirmation) { _ in releaseBusyIfIdle() }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(alert.message(language: language)),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func requestToggle(enabled: Bool) {
        guard !appIsBusy, !storeIsBusy, !isWorking, legacyReceipt == nil,
              !hasUnclassifiedTransaction, enabled != isPersistentlyActive else { return }
        appIsBusy = true
        if enabled {
            pendingActiveState = true
            applyRule()
        } else {
            pendingActiveState = nil
            showRestoreConfirmation = true
        }
    }

    private func cancelPendingAction() {
        showRestoreConfirmation = false
        showChangedRestoreConfirmation = false
        pendingActiveState = nil
        appIsBusy = false
    }

    private func releaseBusyIfIdle() {
        guard !isWorking, !showRestoreConfirmation, !showChangedRestoreConfirmation else { return }
        pendingActiveState = nil
        appIsBusy = false
    }

    private func applyRule() {
        isWorking = true
        let shouldSynchronizeWorkspace = !item.isBundled
            && item.summary.schemaVersion >= 2
            && item.canInspectContents
            && !DevicePatchService.hasActiveTransactions(projectID: project.id)
        Task.detached(priority: .userInitiated) {
            do {
                let sourceProject: PatchProject
                if shouldSynchronizeWorkspace {
                    sourceProject = try PatchProjectLibrary.synchronizeWorkspace(item: item)
                } else {
                    sourceProject = project
                }
                guard let currentRule = sourceProject.rules.first(where: { $0.id == rule.id }) else {
                    throw PatchPackageError.invalidProject
                }
                _ = try DevicePatchService.apply(rule: currentRule, in: sourceProject)
                let appliedProjectID = sourceProject.id
                let appliedPatchName = sourceProject.name
                let appliedRuleID = currentRule.id
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    onUpdate()
                    alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.module_applied_message")
                    Task {
                        await onPatchApplied(appliedProjectID, appliedPatchName, appliedRuleID)
                    }
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    alert = operationError(error)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
                }
            }
        }
    }

    private func prepareRestore() {
        guard let receipt = DevicePatchService.latestReceipt(projectID: project.id, ruleID: rule.id) else {
            cancelPendingAction()
            return
        }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let inspection = try DevicePatchService.inspectRestore(receipt: receipt)
                if !inspection.changedTargets.isEmpty {
                    await MainActor.run {
                        isWorking = false
                        changedPaths = inspection.changedTargets.map(\.displayPath)
                        showChangedRestoreConfirmation = true
                    }
                    return
                }
                try DevicePatchService.restore(receipt: receipt)
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    onUpdate()
                    alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
                    Task {
                        await onPatchUndone(project.id, project.name, rule.id)
                    }
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    alert = operationError(error)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }

    private func restore(allowChangedTargets: Bool) {
        guard let receipt = DevicePatchService.latestReceipt(projectID: project.id, ruleID: rule.id) else {
            cancelPendingAction()
            return
        }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(
                    receipt: receipt,
                    allowChangedTargets: allowChangedTargets
                )
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    onUpdate()
                    alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
                    Task {
                        await onPatchUndone(project.id, project.name, rule.id)
                    }
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    alert = operationError(error)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }

    private func operationError(_ error: PatchPackageError) -> PatchStoreAlert {
        let hidePrivateDetails = project.isPrivate && !item.isAuthorCopy
        return PatchStoreAlert(
            titleKey: "common.failed",
            messageKey: hidePrivateDetails ? "patch.error.private_operation" : error.localizationKey,
            messageArgument: hidePrivateDetails ? nil : error.localizationArgument
        )
    }
}

private enum InstalledContentKind {
    case patch
    case wallpaper

    var localizationKey: String {
        switch self {
        case .patch: return "installed.kind.patch"
        case .wallpaper: return "installed.kind.wallpaper"
        }
    }

    var systemImage: String {
        switch self {
        case .patch: return "shippingbox.fill"
        case .wallpaper: return "photo.fill"
        }
    }
}

private struct InstalledContentKindBadge: View {
    let kind: InstalledContentKind
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .accessibilityHidden(true)
            Text(language.text(kind.localizationKey))
        }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(AppTheme.accent.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .combine)
    }
}

struct PatchUnlockView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PatchProjectStore
    let request: PatchPasswordRequest
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(language.text("patch.password"), text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(unlock)
                        .onChange(of: password) { _ in
                            store.clearUnlockError()
                        }
                    if let errorKey = store.unlockErrorKey {
                        Text(language.text(errorKey))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    if let origin = request.origin {
                        Text(language.text(
                            "patch.password_repo_contact",
                            origin.repositoryName
                        ))
                    } else {
                        Text(language.text("patch.password_once_message"))
                    }
                }
            }
            .navigationTitle(language.text("patch.unlock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("patch.unlock"), action: unlock)
                        .disabled(password.isEmpty || store.isBusy)
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        store.unlock(password: password)
    }
}

private struct PatchStorePresentationModifier: ViewModifier {
    @ObservedObject var store: PatchProjectStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.passwordRequest, onDismiss: store.cancelUnlock) { request in
                PatchUnlockView(store: store, request: request)
            }
    }
}

extension View {
    func patchStorePresentation(_ store: PatchProjectStore) -> some View {
        modifier(PatchStorePresentationModifier(store: store))
    }
}

private struct PatchProjectDetailView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PatchProjectStore
    let projectID: UUID
    @State private var showEditor = false
    @State private var editingRule: PatchRule?
    @State private var showRestoreConfirmation = false
    @State private var showChangedRestoreConfirmation = false
    @State private var showResetConfirmation = false
    @State private var restoreChangedPaths: [String] = []
    @State private var isWorking = false
    @State private var actionAlert: PatchStoreAlert?
    @State private var shareRequest: PatchShareRequest?

    private var item: PatchLibraryItem? {
        store.items.first(where: { $0.id == projectID })
    }

    private var receipt: PatchTransactionReceipt? {
        DevicePatchService.latestReceipt(projectID: projectID)
    }

    private var activeRuleCount: Int {
        guard let project = item?.project else { return 0 }
        if receipt != nil { return project.rules.count }
        return project.rules.filter {
            DevicePatchService.isRuleApplied(projectID: projectID, ruleID: $0.id)
        }.count
    }

    private var hasActiveModules: Bool {
        receipt != nil || activeRuleCount > 0 || hasUnclassifiedActiveTransaction
    }

    private var hasUnclassifiedActiveTransaction: Bool {
        receipt == nil && activeRuleCount == 0
            && DevicePatchService.hasActiveTransactions(projectID: projectID)
    }

    private func isRuleActive(_ rule: PatchRule) -> Bool {
        receipt != nil || DevicePatchService.isRuleApplied(
            projectID: projectID,
            ruleID: rule.id
        )
    }

    private var isWorkspaceProject: Bool {
        (item?.summary.schemaVersion ?? 1) >= 2
    }

    var body: some View {
        List {
            if let item, let project = item.project {
                Section(language.text("patch.information")) {
                    if !project.author.isEmpty {
                        patchInfoRow(
                            label: language.text("patch.author"),
                            value: project.author
                        )
                    }
                    patchInfoRow(label: language.text("patch.privacy")) {
                        Label(
                            language.text(project.isPrivate
                                ? "patch.private"
                                : "patch.public"),
                            systemImage: project.isPrivate
                                ? "eye.slash.fill"
                                : "eye"
                        )
                        .foregroundStyle(project.isPrivate ? AppTheme.accent : Color.secondary)
                    }
                    if let origin = item.origin {
                        patchInfoRow(
                            label: language.text("repository.source"),
                            value: origin.repositoryName
                        )
                    }
                }

                if project.isPrivate && !item.canInspectContents {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                            Text(language.text("patch.private_hidden_title"))
                                .font(.headline)
                            Text(language.text("patch.private_hidden_message"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                } else if isWorkspaceProject && !item.isBundled {
                    Section {
                        ForEach(project.allBundleIdentifiers, id: \.self) { bundleID in
                            Label {
                                Text(bundleID)
                                    .font(.subheadline.monospaced())
                            } icon: {
                                Image(systemName: "app.dashed")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        LabeledContent(language.text("patch.files")) {
                            Text("\(project.rules.count)")
                        }
                        LabeledContent(language.text("patch.folders")) {
                            Text("\(project.directories.count)")
                        }
                        if let workspaceURL = item.workspaceURL {
                            NavigationLink {
                                FileBrowserView(
                                    containerPath: workspaceURL.path,
                                    title: project.name,
                                    bundleID: nil
                                )
                            } label: {
                                Label(
                                    language.text("patch.open_workspace"),
                                    systemImage: "folder"
                                )
                            }
                            .disabled(hasActiveModules)
                        }
                    } header: {
                        Text(language.text("patch.workspace"))
                    } footer: {
                        Text(language.text("patch.workspace_detail_footer"))
                    }
                }

                if item.canInspectContents && !project.rules.isEmpty {
                    Section {
                        ForEach(project.rules) { rule in
                            moduleRow(rule)
                        }
                    } header: {
                        HStack {
                            Text(language.text("patch.rules"))
                            Spacer()
                            Text(language.text(
                                "patch.modules_active",
                                Int64(activeRuleCount),
                                Int64(project.rules.count)
                            ))
                            .font(.caption2.weight(.bold).monospaced())
                            .foregroundStyle(AppTheme.accent)
                        }
                    }
                }

                Section(language.text("patch.password")) {
                    HStack(spacing: 12) {
                        Image(systemName: item.summary.isPasswordProtected ? "lock.fill" : "lock.open")
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 24)
                        Text(language.text(item.summary.isPasswordProtected
                            ? "patch.password_locked"
                            : "patch.no_password"))
                            .font(.subheadline)
                    }
                }

                if receipt != nil {
                    Section {
                        Text(language.text("patch.module_legacy_notice"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button {
                            showResetConfirmation = true
                        } label: {
                            actionLabel("patch.reset", systemImage: "arrow.counterclockwise.circle")
                        }
                        .disabled(isWorking)

                        Button(role: .destructive) {
                            showRestoreConfirmation = true
                        } label: {
                            actionLabel("patch.module_legacy_restore", systemImage: "arrow.uturn.backward.circle")
                        }
                        .disabled(isWorking)
                    } header: {
                        Text(language.text("patch.restore"))
                    }
                }

                if !item.isBundled {
                    Section {
                        Button(action: prepareExport) {
                            actionLabel("patch.export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isWorking || hasActiveModules)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item?.project?.name ?? language.text("patch.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isWorking {
                    ProgressView()
                } else if !isWorkspaceProject,
                          item?.canInspectContents == true,
                          item?.isBundled != true {
                    Button(language.text("patch.edit")) { showEditor = true }
                        .disabled(item?.project == nil || hasActiveModules)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let item, let project = item.project {
                PatchProjectEditorView(
                    existingProject: project,
                    passwordIsProtected: item.summary.isPasswordProtected
                ) { updatedProject, _ in
                    store.update(project: updatedProject)
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            PatchRuleEditorView(rule: rule) { updatedRule in
                updateRule(updatedRule)
            }
        }
        .confirmationDialog(
            language.text("patch.restore_confirm_title"),
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.restore"), role: .destructive) { prepareRestore() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.restore_confirm_message"))
        }
        .confirmationDialog(
            language.text("patch.restore_changed_title"),
            isPresented: $showChangedRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.restore_changed_action"), role: .destructive) {
                restore(allowChangedTargets: true)
            }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(changedRestoreMessage)
        }
        .confirmationDialog(
            language.text("patch.reset_confirm_title"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.reset"), role: .destructive) { resetToAppliedState() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.reset_confirm_message"))
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(alert.message(language: language)),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
        .sheet(item: $shareRequest) { request in
            PatchActivityView(items: [request.url])
                .ignoresSafeArea()
        }
    }

    private func actionLabel(_ key: String, systemImage: String) -> some View {
        Label(language.text(key), systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func patchInfoRow(
        label: String,
        value: String
    ) -> some View {
        patchInfoRow(label: label) {
            Text(value)
                .foregroundStyle(.primary)
        }
    }

    private func patchInfoRow<Content: View>(
        label: String,
        @ViewBuilder value: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value()
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }

    private func ruleSummary(_ rule: PatchRule) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rule.bundleID)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(rule.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Label(rule.replacementFilename, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
        }
        .padding(.vertical, 3)
    }

    private func moduleRow(_ rule: PatchRule) -> some View {
        HStack(spacing: 12) {
            if !isWorkspaceProject {
                Button {
                    guard !hasActiveModules else { return }
                    editingRule = rule
                } label: {
                    ruleSummary(rule)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(hasActiveModules)
                .accessibilityHint(language.text("patch.edit_rule_hint"))
            } else {
                ruleSummary(rule)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .trailing, spacing: 5) {
                Text(language.text("patch.module_start"))
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(.secondary)
                Text(language.text(isRuleActive(rule)
                    ? "patch.module_running"
                    : "patch.module_ready"))
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(isRuleActive(rule) ? Color.green : Color.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 5)
    }

    private func updateRule(_ updatedRule: PatchRule) {
        guard var project = item?.project,
              let index = project.rules.firstIndex(where: { $0.id == updatedRule.id }) else {
            return
        }
        project.rules[index] = updatedRule
        project.updatedAt = Date()
        do {
            try PatchPackageCodec.validate(project)
            store.update(project: project)
        } catch let error as PatchPackageError {
            actionAlert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: error.localizationKey,
                messageArgument: error.localizationArgument
            )
        } catch {
            actionAlert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: "patch.error.invalid_project"
            )
        }
    }

    private func prepareExport() {
        guard let item, !item.isBundled else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                if item.summary.schemaVersion >= 2, item.canInspectContents {
                    _ = try PatchProjectLibrary.synchronizeWorkspace(item: item)
                }
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    shareRequest = PatchShareRequest(url: item.packageURL)
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: "patch.error.invalid_project"
                    )
                }
            }
        }
    }

    private var changedRestoreMessage: String {
        guard item?.project?.isPrivate != true || item?.isAuthorCopy == true else {
            return language.text(
                "patch.restore_changed_private_message",
                Int64(restoreChangedPaths.count)
            )
        }
        var visiblePaths = restoreChangedPaths.prefix(5).joined(separator: "\n")
        if restoreChangedPaths.count > 5 {
            visiblePaths += "\n…"
        }
        return language.text(
            "patch.restore_changed_message",
            Int64(restoreChangedPaths.count),
            visiblePaths
        )
    }

    private func prepareRestore() {
        guard let receipt else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let inspection = try DevicePatchService.inspectRestore(receipt: receipt)
                if inspection.changedTargets.isEmpty {
                    try DevicePatchService.restore(receipt: receipt)
                    await MainActor.run {
                        isWorking = false
                        actionAlert = PatchStoreAlert(
                            titleKey: "common.done",
                            messageKey: "patch.restored_message"
                        )
                    }
                } else {
                    await MainActor.run {
                        isWorking = false
                        restoreChangedPaths = inspection.changedTargets.map(\.displayPath)
                        showChangedRestoreConfirmation = true
                    }
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: "patch.error.restore"
                    )
                }
            }
        }
    }

    private func restore(allowChangedTargets: Bool) {
        guard let receipt else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(
                    receipt: receipt,
                    allowChangedTargets: allowChangedTargets
                )
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }

    private func resetToAppliedState() {
        guard let receipt, let project = item?.project else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.resetToAppliedState(
                    receipt: receipt,
                    project: project
                )
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.done",
                        messageKey: "patch.reset_message"
                    )
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: "patch.error.reset"
                    )
                }
            }
        }
    }

    private func privateErrorKey(for error: PatchPackageError) -> String {
        guard item?.project?.isPrivate == true,
              item?.isAuthorCopy == false else {
            return error.localizationKey
        }
        return "patch.error.private_operation"
    }

    private func privateErrorArgument(for error: PatchPackageError) -> String? {
        guard item?.project?.isPrivate == true,
              item?.isAuthorCopy == false else {
            return error.localizationArgument
        }
        return nil
    }
}

private struct PatchShareRequest: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PatchActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

// This decorative border uses the iOS display clock directly. It does not rely
// on SwiftUI's animation TimelineView scheduler or an async Canvas snapshot.
private struct NativeActivitySilverOrbit: UIViewRepresentable {
    let reduceMotion: Bool

    func makeUIView(context: Context) -> ActivitySilverOrbitUIView {
        let view = ActivitySilverOrbitUIView(frame: .zero)
        view.configure(reduceMotion: reduceMotion)
        return view
    }

    func updateUIView(_ uiView: ActivitySilverOrbitUIView, context: Context) {
        uiView.configure(reduceMotion: reduceMotion)
    }

    static func dismantleUIView(_ uiView: ActivitySilverOrbitUIView, coordinator: ()) {
        uiView.stopAnimating()
    }
}

private final class ActivitySilverOrbitFrameTarget: NSObject {
    weak var view: ActivitySilverOrbitUIView?

    init(view: ActivitySilverOrbitUIView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        view?.advanceFrame(at: link.targetTimestamp)
    }
}

private final class ActivitySilverOrbitUIView: UIView {
    private var displayLink: CADisplayLink?
    private var perimeter = Path()
    private var clockOrigin = CACurrentMediaTime()
    private var lapDuration: CFTimeInterval = 2.0
    private var phase = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentScaleFactor = UIScreen.main.scale
        layer.drawsAsynchronously = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(resumeAfterForeground),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(pauseWhileBackgrounded),
            name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func configure(reduceMotion: Bool) {
        // The user explicitly requested a moving perimeter. Reduced Motion
        // attenuates its speed/glow instead of replacing it with a static line.
        let newDuration: CFTimeInterval = reduceMotion ? 3.2 : 2.0
        guard newDuration != lapDuration else { return }
        let now = CACurrentMediaTime()
        clockOrigin = now - phase * newDuration
        lapDuration = newDuration
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopAnimating()
        } else {
            startAnimating()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = bounds.insetBy(dx: 1.6, dy: 1.6)
        guard rect.width > 0, rect.height > 0 else { return }
        perimeter = RoundedRectangle(cornerRadius: 10.4, style: .continuous).path(in: rect)
        setNeedsDisplay()
    }

    private func startAnimating() {
        guard window != nil else { return }
        clockOrigin = CACurrentMediaTime() - phase * lapDuration
        if displayLink == nil {
            let target = ActivitySilverOrbitFrameTarget(view: self)
            let link = CADisplayLink(target: target, selector: #selector(ActivitySilverOrbitFrameTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = UIApplication.shared.applicationState != .active
        advanceFrame(at: CACurrentMediaTime())
    }

    func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func resumeAfterForeground() {
        startAnimating()
    }

    @objc private func pauseWhileBackgrounded() {
        displayLink?.isPaused = true
    }

    func advanceFrame(at timestamp: CFTimeInterval) {
        let now = timestamp > 0 ? timestamp : CACurrentMediaTime()
        phase = max(0, now - clockOrigin).truncatingRemainder(dividingBy: lapDuration) / lapDuration
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !perimeter.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        context.setShouldAntialias(true)
        context.setStrokeColor(UIColor(white: 0.32, alpha: 0.38).cgColor)
        context.setLineWidth(0.7)
        context.addPath(perimeter.cgPath)
        context.strokePath()

        // One composited monochrome shadow, not a separate blur per sample.
        context.saveGState()
        context.setShadow(
            offset: .zero, blur: lapDuration > 2.0 ? 2.5 : 4.0,
            color: UIColor(white: 0.66, alpha: 0.36).cgColor
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        let samples = 36
        let step = 0.20 / Double(samples)
        context.setLineWidth(1.9)
        context.setLineCap(.butt)
        for index in 0..<samples {
            let intensity = Double(index + 1) / Double(samples)
            let opacity = 0.04 + 0.88 * pow(intensity, 1.7)
            context.setStrokeColor(UIColor(white: CGFloat(0.36 + 0.50 * intensity), alpha: CGFloat(opacity)).cgColor)
            context.addPath(segment(start: phase + Double(index) * step, length: step + 0.00015).cgPath)
            context.strokePath()
        }
        context.endTransparencyLayer()
        context.restoreGState()

        context.setStrokeColor(UIColor(white: 0.92, alpha: 0.92).cgColor)
        context.setLineWidth(1.15)
        context.setLineCap(.round)
        context.addPath(segment(start: phase + 0.18, length: 0.02).cgPath)
        context.strokePath()
    }

    private func segment(start: Double, length: Double) -> Path {
        let fraction = start.truncatingRemainder(dividingBy: 1.0)
        let from = CGFloat(fraction < 0 ? fraction + 1.0 : fraction)
        let to = from + CGFloat(length)
        var piece = perimeter.trimmedPath(from: from, to: min(to, 1.0))
        if to > 1.0 + 0.0000001 {
            piece.addPath(perimeter.trimmedPath(from: 0, to: to - 1.0))
        }
        return piece
    }
}
