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

    private var hasLocalContent: Bool {
        !store.items.isEmpty
    }

    private var totalRuleCount: Int {
        store.items.reduce(0) { count, item in
            guard item.canInspectContents, let project = item.project else { return count }
            return count + project.rules.count
        }
    }

    private var activeRuleCount: Int {
        store.items.reduce(0) { count, item in
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
            VStack(alignment: .leading, spacing: 3) {
                Text("AURA CONSOLE")
                    .font(.system(size: 17, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                Text(language.text("installed.online"))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("V\(AppInfo.appVersion)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.38)))
        }
        .padding(.horizontal, 3)
    }

    private var faxAuraBanner: some View {
        Image("ActivityHeaderArt")
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.76), lineWidth: 1)
            }
            .accessibilityLabel("Fax Aura")
    }

    private var activityCard: some View {
        Button(action: onOpenLogs) {
            HStack(spacing: 9) {
                activityLogIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("installed.activity"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text(appLog.entries.last ?? language.text("installed.no_recent_activity"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Circle()
                    .fill(isModuleOperationInProgress ? Color.orange : Color.white)
                    .frame(width: 7, height: 7)
                    .shadow(color: .white.opacity(0.75), radius: 6)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.09), Color.white.opacity(0.025), Color.black.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.gray.opacity(0.22), lineWidth: 0.8)
            }
            .overlay {
                activityOrbitMotion
            }
            .shadow(color: .black.opacity(0.32), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private var activityOrbitMotion: some View {
        TimelineView(
            .animation(
                minimumInterval: reduceMotion ? 0.08 : 1.0 / 30.0,
                paused: false
            )
        ) { timeline in
            let lapDuration = reduceMotion ? 5.4 : 2.2
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: lapDuration) / lapDuration
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .inset(by: 1.8)
                    .stroke(Color.gray.opacity(0.30), lineWidth: 0.9)
                activityOrbitSegments(
                    progress: progress,
                    segmentLength: reduceMotion ? 0.15 : 0.28
                )
                if !reduceMotion {
                    activityOrbitSegments(
                        progress: (progress + 0.52).truncatingRemainder(dividingBy: 1),
                        segmentLength: 0.08
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func activityOrbitSegments(progress: Double, segmentLength: Double) -> some View {
        let start = CGFloat(progress)
        let end = start + CGFloat(segmentLength)
        let metallicGradient = AngularGradient(
            colors: [
                Color(white: 0.30),
                Color(white: 0.72),
                .white,
                Color(white: 0.48),
                .white,
                Color(white: 0.36)
            ],
            center: .center,
            startAngle: .degrees(progress * 360),
            endAngle: .degrees(progress * 360 + 360)
        )

        return ZStack {
            activityOrbitArc(from: start, to: min(end, 1), gradient: metallicGradient)
            if end > 1 {
                activityOrbitArc(from: 0, to: end - 1, gradient: metallicGradient)
            }
        }
    }

    private func activityOrbitArc(
        from start: CGFloat,
        to end: CGFloat,
        gradient: AngularGradient
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .inset(by: 2.1)
                .trim(from: start, to: end)
                .stroke(
                    Color.black.opacity(0.82),
                    style: StrokeStyle(lineWidth: 5.4, lineCap: .round)
                )
                .offset(y: 0.8)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .inset(by: 2.1)
                .trim(from: start, to: end)
                .stroke(
                    Color.gray.opacity(0.9),
                    style: StrokeStyle(lineWidth: 4.2, lineCap: .round)
                )
                .shadow(color: Color.gray.opacity(0.95), radius: 7)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .inset(by: 2.1)
                .trim(from: start, to: end)
                .stroke(
                    gradient,
                    style: StrokeStyle(lineWidth: 3.1, lineCap: .round)
                )
                .shadow(color: .white.opacity(0.88), radius: 4)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .inset(by: 3.6)
                .trim(from: start, to: end)
                .stroke(
                    .white.opacity(0.92),
                    style: StrokeStyle(lineWidth: 0.8, lineCap: .round)
                )
        }
    }

    private var activityLogIcon: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.08))
            Image(systemName: "waveform.path")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
        .frame(width: 30, height: 30)
    }

    private var moduleStatusPanel: some View {
        HStack(spacing: 0) {
            statusMetric(
                symbol: "square.grid.2x2.fill",
                value: "\(totalRuleCount)",
                label: language.text("installed.modules")
            )
            statusDivider
            statusMetric(
                symbol: "dot.radiowaves.left.and.right",
                value: "\(activeRuleCount)",
                label: language.text("installed.active")
            )
            statusDivider
            statusMetric(
                symbol: "checkmark.shield.fill",
                value: language.text("installed.safe"),
                label: language.text("installed.mode")
            )
        }
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.26), lineWidth: 0.8))
    }

    private var statusDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.20))
            .frame(width: 1, height: 30)
    }

    private func statusMetric(symbol: String, value: String, label: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(value)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(.white)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
            Text(language.text(key))
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.30), lineWidth: 0.8))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var functionsHeading: some View {
        HStack(alignment: .center, spacing: 9) {
            Capsule()
                .fill(.white)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("installed.functions"))
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Text(language.text("installed.available"))
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(language.text("installed.active_total", Int64(activeRuleCount), Int64(totalRuleCount)))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.top, 4)
    }

    init(
        onOpenSettings: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {}
    ) {
        self.onOpenSettings = onOpenSettings
        self.onOpenLogs = onOpenLogs
#if targetEnvironment(simulator)
        _showCreate = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("--simulate-patch-editor")
        )
#endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    consoleBrandHeader
                    faxAuraBanner
                    activityCard
                    moduleStatusPanel
                    quickActions
                    functionsHeading

                    if !hasLocalContent && store.isBusy {
                        loadingState
                    } else if !hasLocalContent {
                        emptyState
                    } else {
                        ForEach(store.items) { item in
                            itemRow(item)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle(language.text("tab.installed"))
            .navigationBarTitleDisplayMode(.inline)
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
        HStack(spacing: 9) {
            Capsule()
                .fill(.white)
                .frame(width: 3, height: 48)
            HStack(spacing: 8) {
                Image("ActivityHeaderArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 31)
                    .padding(2)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.42), lineWidth: 0.7)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            PatchModuleToggle(
                item: item,
                project: project,
                rule: rule,
                storeIsBusy: store.isBusy,
                appIsBusy: $isModuleOperationInProgress,
                onUpdate: store.reload
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.075), Color.white.opacity(0.025), Color.black.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(0.34), lineWidth: 0.8)
        }
    }

    private func projectCard(_ item: PatchLibraryItem) -> some View {
        PatchProjectRow(item: item, language: language)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func deleteMenu(_ item: PatchLibraryItem) -> some View {
        Button(role: .destructive) {
            guard !isModuleOperationInProgress else { return }
            store.delete(item)
        } label: {
            Label(language.text("common.delete"), systemImage: "trash")
        }
        .disabled(isModuleOperationInProgress)
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

    @State private var showChangedRestoreConfirmation = false
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
        Button {
            requestToggle(enabled: !isActive)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(language.text(isActive ? "patch.module_running" : "patch.module_start"))
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(isActive ? Color.black : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                isActive ? Color.green : Color.white.opacity(0.08),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        isActive ? Color.green.opacity(0.95) : Color.gray.opacity(0.48),
                        lineWidth: 0.9
                    )
            }
            .shadow(color: isActive ? Color.green.opacity(0.25) : .clear, radius: 4)
            .animation(.easeInOut(duration: 0.16), value: isActive)
        }
        .buttonStyle(.plain)
        .disabled(
            appIsBusy || storeIsBusy || legacyReceipt != nil || hasUnclassifiedTransaction
        )
        .accessibilityLabel(
            "\(project.name), \(language.text(isActive ? "patch.module_running" : "patch.module_start"))"
        )
        .accessibilityValue(language.text(isActive ? "patch.module_running" : "patch.module_ready"))
        .frame(width: 104)
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
        pendingActiveState = enabled
        if enabled {
            applyRule()
        } else {
            prepareRestore()
        }
    }

    private func cancelPendingAction() {
        showChangedRestoreConfirmation = false
        pendingActiveState = nil
        appIsBusy = false
    }

    private func releaseBusyIfIdle() {
        guard !isWorking, !showChangedRestoreConfirmation else { return }
        pendingActiveState = nil
        appIsBusy = false
    }

    private func applyRule() {
        isWorking = true
        let shouldSynchronizeWorkspace = item.summary.schemaVersion >= 2
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
                await MainActor.run {
                    isWorking = false
                    appIsBusy = false
                    onUpdate()
                    alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.module_applied_message")
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
                } else if isWorkspaceProject {
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

                Section {
                    Button(action: prepareExport) {
                        actionLabel("patch.export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isWorking || hasActiveModules)
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
                } else if !isWorkspaceProject, item?.canInspectContents == true {
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
        guard let item else { return }
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
