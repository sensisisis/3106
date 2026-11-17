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
    @EnvironmentObject private var draftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var store: PatchProjectStore
    @AppStorage(FeatureVisibility.cleanerStorageKey) private var cleanerEnabled = true
    @State private var showCreate = false
    @State private var showImporter = false
    @State private var showWallpaperImporter = false
    @State private var showCleaner = false
    @State private var searchText = ""
    @State private var wallpaperPackages: [WallpaperStagedPackage] = []
    @State private var wallpaperImportFeedback: WallpaperImportFeedback?
    @State private var wallpaperPendingDeletion: WallpaperStagedPackage?
    @State private var isImportingWallpapers = false
    @State private var isModuleOperationInProgress = false
    @State private var showSimulatedWallpaperDetail = false
    @State private var simulatedWallpaperDetailGate = OneShotPresentationGate()
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    private var filteredItems: [PatchLibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        return store.items.filter { item in
            if item.packageURL.lastPathComponent.localizedCaseInsensitiveContains(query) {
                return true
            }
            guard let project = item.project else { return false }
            if project.name.localizedCaseInsensitiveContains(query)
                || project.author.localizedCaseInsensitiveContains(query) {
                return true
            }
            guard item.canInspectContents else { return false }
            return project.allBundleIdentifiers.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
                || project.directories.contains {
                    $0.relativePath.localizedCaseInsensitiveContains(query)
                }
                || project.rules.contains {
                    $0.relativePath.localizedCaseInsensitiveContains(query)
                        || $0.replacementFilename.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var filteredWallpaperPackages: [WallpaperStagedPackage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return wallpaperPackages }
        return wallpaperPackages.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasLocalContent: Bool {
        !store.items.isEmpty
    }

    private var hasSearchResults: Bool {
        !filteredItems.isEmpty
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
            VStack(spacing: 0) {
                AuraConsoleHeader(
                    title: language.text("home.card.patches"),
                    subtitle: "PATCH CONTROL / MODULES",
                    systemImage: "square.stack.3d.up.fill"
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                AppSearchField(
                    text: $searchText,
                    prompt: language.text("patch.search"),
                    clearLabel: language.text("common.clear")
                )
                Divider()
                List {
                    if !hasLocalContent && store.isBusy {
                        loadingState
                            .listRowSeparator(.hidden)
                    } else if !hasLocalContent {
                        emptyState
                            .listRowSeparator(.hidden)
                    } else if !hasSearchResults && !store.isBusy {
                        searchEmptyState
                            .listRowSeparator(.hidden)
                    } else {
                        if !filteredItems.isEmpty {
                            Section(language.text("patch.title")) {
                                ForEach(filteredItems) { item in
                                    itemRow(item)
                                }
                                .onDelete { offsets in
                                    guard !isModuleOperationInProgress else { return }
                                    offsets.map { filteredItems[$0] }.forEach(store.delete)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(AppTheme.pageBackground)
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel(language.text("settings.title"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showCreate = true
                        } label: {
                            Label(language.text("patch.new"), systemImage: "doc.badge.plus")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label(language.text("patch.import"), systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        if store.isBusy {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .disabled(store.isBusy || isModuleOperationInProgress)
                    .accessibilityLabel(language.text("patch.add"))
                }
            }
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
                PatchProjectRow(item: item, language: language)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            HStack(spacing: 8) {
                NavigationLink {
                    PatchProjectDetailView(store: store, projectID: item.id)
                } label: {
                    PatchProjectRow(item: item, language: language)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                projectModuleControls(item)
            }
            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func projectModuleControls(_ item: PatchLibraryItem) -> some View {
        if let project = item.project,
           item.canInspectContents,
           !project.rules.isEmpty {
            VStack(spacing: 5) {
                ForEach(project.rules) { rule in
                    PatchModuleToggle(
                        item: item,
                        project: project,
                        rule: rule,
                        storeIsBusy: store.isBusy,
                        appIsBusy: $isModuleOperationInProgress,
                        onUpdate: store.reload
                    )
                }
            }
            .frame(width: 104)
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

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("patch.search_empty"))
                .font(.headline)
            Text(language.text("patch.search_empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                InstalledContentKindBadge(kind: .patch, language: language)
                if let author = item.project?.author, !author.isEmpty {
                    Text(language.text("patch.by_author", author))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(rowDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var rowDetail: String {
        if item.isLocked {
            return language.text("patch.tap_to_unlock")
        }
        if item.project?.isPrivate == true, !item.isAuthorCopy {
            return language.text("patch.private_received")
        }
        return language.text(
            item.summary.schemaVersion >= 2
                ? "patch.workspace_items_count"
                : "patch.rules_count",
            Int64((item.project?.rules.count ?? 0) + (item.project?.directories.count ?? 0))
        )
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
    @State private var changedPaths: [String] = []
    @State private var alert: PatchStoreAlert?

    private var legacyReceipt: PatchTransactionReceipt? {
        DevicePatchService.latestReceipt(projectID: item.id)
    }

    private var isActive: Bool {
        legacyReceipt != nil || DevicePatchService.isRuleApplied(
            projectID: project.id,
            ruleID: rule.id
        )
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
            Text(rule.relativePath)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
            Text(language.text("patch.module_start"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(language.text(isActive ? "patch.module_running" : "patch.module_ready"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(isActive ? Color.green : Color.secondary)
                .lineLimit(1)
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .frame(height: 23)
            } else {
                Toggle(isOn: Binding(
                    get: { isActive },
                    set: { requestToggle(enabled: $0) }
                )) {
                    EmptyView()
                }
                .labelsHidden()
                .tint(.green)
                .scaleEffect(0.82)
                .disabled(
                    appIsBusy || storeIsBusy || legacyReceipt != nil || hasUnclassifiedTransaction
                )
                .accessibilityLabel(rule.relativePath)
                .accessibilityValue(language.text(isActive
                    ? "patch.module_running"
                    : "patch.module_ready"))
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 6)
        .frame(width: 104)
        .background(
            Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
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
              !hasUnclassifiedTransaction, enabled != isActive else { return }
        appIsBusy = true
        if enabled {
            applyRule()
        } else {
            prepareRestore()
        }
    }

    private func cancelPendingAction() {
        showChangedRestoreConfirmation = false
        appIsBusy = false
    }

    private func releaseBusyIfIdle() {
        guard !isWorking, !showChangedRestoreConfirmation else { return }
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
