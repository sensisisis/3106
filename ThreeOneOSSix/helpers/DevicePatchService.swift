import Foundation

enum DevicePatchService {
    static func apply(
        project: PatchProject,
        sourceProjectID: UUID? = nil
    ) throws -> PatchTransactionReceipt {
        let bundleIDs = orderedBundleIdentifiers(in: project)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                },
                backupCenter: .shared,
                sourceProjectID: sourceProjectID
            )
        }
    }

    static func apply(rule: PatchRule, in project: PatchProject) throws -> PatchTransactionReceipt {
        let ruleProject = PatchProject(
            id: PatchTransaction.ruleTransactionProjectID(
                projectID: project.id,
                ruleID: rule.id
            ),
            name: project.name,
            author: project.author,
            isPrivate: project.isPrivate,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt,
            bundleIdentifiers: [rule.bundleID],
            rules: [rule]
        )
        return try apply(project: ruleProject, sourceProjectID: project.id)
    }

    static func latestReceipt(projectID: UUID, ruleID: UUID) -> PatchTransactionReceipt? {
        latestReceipt(projectID: PatchTransaction.ruleTransactionProjectID(
            projectID: projectID,
            ruleID: ruleID
        ))
    }

    static func isRuleApplied(projectID: UUID, ruleID: UUID) -> Bool {
        latestReceipt(projectID: projectID, ruleID: ruleID) != nil
    }

    static func hasActiveTransactions(projectID: UUID) -> Bool {
        if latestReceipt(projectID: projectID) != nil { return true }
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return true }
        return PatchTransaction.hasActiveTransactions(
            sourceProjectID: projectID,
            backupRoot: backupRoot
        )
    }

    static func inspectRestore(receipt: PatchTransactionReceipt) throws -> PatchRestoreInspection {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.inspectRestore(
                receipt: receipt,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowChangedTargets: Bool = false
    ) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.restore(
                receipt: receipt,
                allowChangedTargets: allowChangedTargets,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func resetToAppliedState(
        receipt: PatchTransactionReceipt,
        project: PatchProject
    ) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.resetToAppliedState(
                receipt: receipt,
                fallbackProject: project,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    private static func orderedBundleIdentifiers(in project: PatchProject) -> [String] {
        project.allBundleIdentifiers
    }

    private static func withResolvedContainers<T>(
        bundleIDs: [String],
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        var roots: [String: URL] = [:]
        var grants: [Int64] = []
        defer {
            for grant in grants { SandboxAccess.release(grant) }
        }

        for bundleID in bundleIDs {
            guard let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
                  ContainerStore.isApplicationContainerPath(path) else {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
            // Keep the token for the whole transaction; a release before the
            // copy/restore would revoke it on bad_query.
            let grant = ContainerStore.grantContainerAccess(path)
            if grant >= 0 { grants.append(grant) }
            roots[bundleID] = PatchPathValidator.canonicalFileURL(URL(fileURLWithPath: path, isDirectory: true))
        }
        return try operation(roots)
    }
}
