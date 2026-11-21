import Foundation
import Security
import SwiftUI
import UIKit
import CryptoKit
import Darwin

private enum LicenseValidationOutcome {
    case active(SupabaseLicenseResponse)
    case rejected(SupabaseLicenseResponse)
    case transportFailure(String)
}

enum LicenseActivationResult {
    case success
    case failure(String)
}

@MainActor
final class LicenseSession: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var notice: String?
    @Published private(set) var isRestoring = false

    var expirationDate: Date? {
        guard let timestamp = UserDefaults.standard.object(forKey: expirationStorage) as? Double,
              timestamp.isFinite, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    var hasStoredLicense: Bool {
        guard let key = storedKey else { return false }
        return !key.isEmpty && storedSessionVersion(for: normalized(key)) != nil
    }

    var isPermanentLicense: Bool {
        isAuthorized && hasStoredLicense && expirationDate == nil
    }

    private let sessionVersionStorage = "3106.supabase.license.session-version"
    private let fallbackDeviceIDStorage = "3106.supabase.license.fallback-device-id"
    private let expirationStorage = "3106.supabase.license.expires-at"
    private let supabaseRPCURL = "https://skarpahwcwkqdfxgtvlp.supabase.co/rest/v1/rpc/fax_license_validate"
    private let supabaseRestoreRPCURL = "https://skarpahwcwkqdfxgtvlp.supabase.co/rest/v1/rpc/fax_license_restore"
    private let supabasePatchEventRPCURL = "https://skarpahwcwkqdfxgtvlp.supabase.co/rest/v1/rpc/fax_license_record_patch_event"
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNrYXJwYWh3Y3drcWRmeGd0dmxwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIwMjc3NTYsImV4cCI6MjEwNzYwMzc1Nn0.PUh5QIs_W61En2PdyML31uzMFG_8NvCAHeRp1qYBzFw"
    private var validationGeneration = 0
    private var explicitActivationInFlight = false
    private var cachedDeviceID: String?
    private var deviceIdentityResolutionFailed = false

    init() {
        isRestoring = LicenseKeychain.load()?.isEmpty == false
    }

    func runForegroundSession(for phase: ScenePhase) async {
        guard phase == .active else { return }

        await restore()
        var nextHeartbeat = Date().addingTimeInterval(60)

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            if isAuthorized, localExpirationHasPassed {
                deauthorize()
                notice = "license.error.checking"
                await heartbeat()
                nextHeartbeat = Date().addingTimeInterval(60)
            }

            guard Date() >= nextHeartbeat,
                  let key = storedKey,
                  storedSessionVersion(for: normalized(key)) != nil else {
                continue
            }
            await heartbeat()
            nextHeartbeat = Date().addingTimeInterval(60)
        }
    }

    func activate(_ rawKey: String) async -> LicenseActivationResult {
        let key = normalized(rawKey)
        guard !key.isEmpty else {
            return .failure("license.error.empty")
        }

        explicitActivationInFlight = true
        isRestoring = false
        notice = nil
        let generation = beginValidation()
        defer { explicitActivationInFlight = false }

        let outcome = await validate(
            key,
            sessionVersion: storedSessionVersion(for: key),
            claim: true
        )
        guard generation == validationGeneration, !Task.isCancelled else {
            return .failure("license.error.superseded")
        }
        return apply(outcome, key: key)
    }

    private func restore() async {
        guard !explicitActivationInFlight else { return }
        let generation = beginValidation()
        let savedKey = storedKey
        isRestoring = savedKey?.isEmpty == false
        defer {
            if generation == validationGeneration {
                isRestoring = false
            }
        }
        guard let savedKey, !savedKey.isEmpty else {
            guard generation == validationGeneration else { return }
            deauthorize()
            return
        }

        let key = normalized(savedKey)
        let outcome: LicenseValidationOutcome
        if let sessionVersion = storedSessionVersion(for: key) {
            outcome = await validate(key, sessionVersion: sessionVersion, claim: false)
        } else {
            // UserDefaults is cleared when the IPA is removed. Recover only the
            // server session already bound to this Keychain device ID; this RPC
            // cannot claim an unbound or administratively released key.
            outcome = await validate(
                key,
                sessionVersion: nil,
                claim: false,
                restoreOnly: true
            )
        }
        guard generation == validationGeneration, !Task.isCancelled else { return }
        _ = apply(outcome, key: key)
    }

    private func heartbeat() async {
        guard !explicitActivationInFlight else { return }
        guard let key = storedKey, !key.isEmpty,
              let sessionVersion = storedSessionVersion(for: normalized(key)) else {
            deauthorize()
            notice = "license.error.resume"
            return
        }

        let normalizedKey = normalized(key)
        let generation = beginValidation()
        let outcome = await validate(
            normalizedKey,
            sessionVersion: sessionVersion,
            claim: false
        )
        guard generation == validationGeneration, !Task.isCancelled else { return }
        _ = apply(outcome, key: normalizedKey)
    }

    /// Reports only a patch that DevicePatchService already applied successfully.
    /// Telemetry is best-effort: failures never roll back or block the local patch.
    func recordPatchApplied(projectID: UUID, patchName: String, ruleID: UUID) async {
        await recordPatchEvent(
            rpcURL: supabasePatchEventRPCURL,
            projectID: projectID,
            patchName: patchName,
            ruleID: ruleID
        )
    }

    /// Reports only a patch whose original files DevicePatchService restored successfully.
    /// Telemetry is best-effort and never changes the outcome of the local restore.
    func recordPatchUndone(projectID: UUID, patchName: String, ruleID: UUID) async {
        await recordPatchEvent(
            rpcURL: supabasePatchUndoEventRPCURL,
            projectID: projectID,
            patchName: patchName,
            ruleID: ruleID
        )
    }

    private func recordPatchEvent(
        rpcURL: String,
        projectID: UUID,
        patchName: String,
        ruleID: UUID
    ) async {
        guard isAuthorized,
              let savedKey = storedKey,
              let sessionVersion = storedSessionVersion(for: normalized(savedKey)),
              let stableDeviceID = deviceID,
              let url = URL(string: rpcURL),
              let appBundleID = Bundle.main.bundleIdentifier else {
            return
        }

        let cleanPatchName = patchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let appVersion = AppInfo.appVersion
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let iosVersion = UIDevice.current.systemVersion
        guard !cleanPatchName.isEmpty,
              cleanPatchName.count <= 96,
              !cleanPatchName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !appBundleID.isEmpty, appBundleID.count <= 255,
              !appVersion.isEmpty, appVersion.count <= 32,
              !appBuild.isEmpty, appBuild.count <= 32,
              !iosVersion.isEmpty, iosVersion.count <= 32 else {
            return
        }

        let keyHash = SHA256.hash(data: Data(normalized(savedKey).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let payload: [String: Any] = [
            "p_key_hash": keyHash,
            "p_device_id": stableDeviceID,
            "p_session_version": sessionVersion,
            "p_event_id": UUID().uuidString.lowercased(),
            "p_project_id": projectID.uuidString.lowercased(),
            "p_rule_id": ruleID.uuidString.lowercased(),
            "p_patch_name": cleanPatchName,
            "p_app_bundle_id": appBundleID,
            "p_app_version": appVersion,
            "p_app_build": appBuild,
            "p_ios_version": iosVersion
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return
            }
            let result = try JSONDecoder().decode(SupabasePatchEventResponse.self, from: data)
            guard result.ok, result.code == "recorded" else { return }
        } catch {
            // Network/telemetry errors intentionally do not affect patch success.
            return
        }
    }

    private let supabasePatchUndoEventRPCURL = "https://skarpahwcwkqdfxgtvlp.supabase.co/rest/v1/rpc/fax_license_record_patch_undo_event"

    private func apply(
        _ outcome: LicenseValidationOutcome,
        key: String
    ) -> LicenseActivationResult {
        switch outcome {
        case .active(let response):
            guard persistSession(key: key, response: response) else {
                deauthorize()
                notice = "license.error.storage"
                return .failure("license.error.storage")
            }
            isAuthorized = true
            notice = nil
            return .success

        case .rejected(let response):
            let code = response.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let message = messageKey(for: code)
            if code == "paused" {
                guard persistSession(key: key, response: response, preserveExpiration: true) else {
                    clearCredentials()
                    notice = "license.error.storage"
                    return .failure("license.error.storage")
                }
                deauthorize()
            } else if ["not_found", "revoked", "invalid", "expired", "session_released", "device_mismatch"].contains(code) {
                clearCredentials()
            } else {
                deauthorize()
            }
            notice = message
            return .failure(message)

        case .transportFailure(let message):
            deauthorize()
            notice = message
            return .failure(message)
        }
    }

    private func validate(
        _ key: String,
        sessionVersion: Int?,
        claim: Bool,
        restoreOnly: Bool = false
    ) async -> LicenseValidationOutcome {
        let normalizedKey = normalized(key)
        guard !normalizedKey.isEmpty else {
            return .transportFailure("license.error.network")
        }

        let hash = SHA256.hash(data: Data(normalizedKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let rpcURL = restoreOnly ? supabaseRestoreRPCURL : supabaseRPCURL
        guard let url = URL(string: rpcURL) else {
            return .transportFailure("license.error.network")
        }

        let sessionValue: Any
        if let sessionVersion {
            sessionValue = sessionVersion
        } else {
            sessionValue = NSNull()
        }

        guard let stableDeviceID = deviceID else {
            return .transportFailure("license.error.network")
        }

        let payload: [String: Any]
        if restoreOnly {
            payload = [
                "p_key_hash": hash,
                "p_device_id": stableDeviceID,
                "p_device_model": deviceModel,
                "p_device_identifier": machineIdentifier,
                "p_ios_version": UIDevice.current.systemVersion
            ]
        } else {
            payload = [
                "p_key_hash": hash,
                "p_device_id": stableDeviceID,
                "p_device_model": deviceModel,
                "p_device_identifier": machineIdentifier,
                "p_ios_version": UIDevice.current.systemVersion,
                "p_session_version": sessionValue,
                "p_claim": claim
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return .transportFailure("license.error.network")
            }

            let validation = try JSONDecoder().decode(SupabaseLicenseResponse.self, from: data)
            guard isStrictlyValid(validation) else {
                return .transportFailure("license.error.network")
            }

            let code = validation.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if validation.ok {
                guard code == "active", validation.sessionVersion > 0 else {
                    return .transportFailure("license.error.network")
                }
                return .active(validation)
            }
            return .rejected(validation)
        } catch is CancellationError {
            return .transportFailure("license.error.cancelled")
        } catch {
            return .transportFailure("license.error.network")
        }
    }

    private func isStrictlyValid(_ response: SupabaseLicenseResponse) -> Bool {
        let code = response.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty,
              let serverNow = parseServerDate(response.serverNow),
              serverNow.timeIntervalSince1970.isFinite else {
            return false
        }

        if let expiresAt = response.expiresAt {
            guard !expiresAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let expiration = parseServerDate(expiresAt),
                  expiration.timeIntervalSince1970.isFinite else {
                return false
            }
            if response.ok, expiration <= serverNow {
                return false
            }
        }

        if let remainingSeconds = response.remainingSeconds {
            guard remainingSeconds.isFinite else { return false }
            if response.ok, remainingSeconds < 0 { return false }
        }

        if response.ok {
            guard code == "active", response.sessionVersion > 0 else { return false }
        } else {
            guard code != "active" else { return false }
        }
        return true
    }

    private func persistSession(
        key: String,
        response: SupabaseLicenseResponse,
        preserveExpiration: Bool = false
    ) -> Bool {
        guard storeKeyIfNeeded(key) else { return false }
        UserDefaults.standard.set(response.sessionVersion, forKey: sessionVersionStorage)
        persistExpiration(from: response, preserveExisting: preserveExpiration)
        return true
    }

    private func persistExpiration(
        from response: SupabaseLicenseResponse,
        preserveExisting: Bool
    ) {
        guard let expiresAt = response.expiresAt,
              let expiration = parseServerDate(expiresAt),
              let serverNow = parseServerDate(response.serverNow) else {
            if !preserveExisting {
                UserDefaults.standard.removeObject(forKey: expirationStorage)
            }
            return
        }

        let localClockSkew = Date().timeIntervalSince1970 - serverNow.timeIntervalSince1970
        let adjustedExpiration = expiration.addingTimeInterval(localClockSkew)
        guard adjustedExpiration.timeIntervalSince1970.isFinite else {
            if !preserveExisting {
                UserDefaults.standard.removeObject(forKey: expirationStorage)
            }
            return
        }
        UserDefaults.standard.set(
            adjustedExpiration.timeIntervalSince1970,
            forKey: expirationStorage
        )
    }

    private func clearCredentials() {
        LicenseKeychain.delete()
        UserDefaults.standard.removeObject(forKey: sessionVersionStorage)
        UserDefaults.standard.removeObject(forKey: expirationStorage)
        deauthorize()
    }

    private func deauthorize() {
        isAuthorized = false
    }

    private func beginValidation() -> Int {
        validationGeneration += 1
        return validationGeneration
    }

    private var storedKey: String? {
        LicenseKeychain.load()
    }

    private func storedSessionVersion(for key: String) -> Int? {
        guard let savedKey = storedKey, normalized(savedKey) == normalized(key),
              let value = UserDefaults.standard.object(forKey: sessionVersionStorage) as? Int,
              value > 0 else {
            return nil
        }
        return value
    }

    private var localExpirationHasPassed: Bool {
        guard let value = UserDefaults.standard.object(forKey: expirationStorage) as? NSNumber,
              value.doubleValue.isFinite else {
            return false
        }
        return value.doubleValue <= Date().timeIntervalSince1970
    }

    private var deviceModel: String {
        let identifier = machineIdentifier
        let compactIdentifier = identifier.hasPrefix("iPhone")
            ? String(identifier.dropFirst("iPhone".count))
            : identifier
        if let commercialName = Self.iPhoneModels[identifier] ?? Self.iPhoneModels[compactIdentifier] {
            return commercialName
        }
        if UIDevice.current.userInterfaceIdiom == .phone {
            return "iPhone (\(identifier))"
        }
        return "\(UIDevice.current.model) (\(identifier))"
    }

    private var machineIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    private func storeKeyIfNeeded(_ key: String) -> Bool {
        guard LicenseKeychain.load() != key else { return true }
        do {
            try LicenseKeychain.save(key)
            return true
        } catch {
            return false
        }
    }

    private var deviceID: String? {
        if let cachedDeviceID {
            return cachedDeviceID
        }
        guard !deviceIdentityResolutionFailed else { return nil }

        let defaults = UserDefaults.standard
        let vendorID = (UIDevice.current.identifierForVendor?.uuidString)
            .flatMap(Self.nonEmptyDeviceID)
        let legacyFallback = defaults.string(forKey: fallbackDeviceIDStorage)
            .flatMap(Self.nonEmptyDeviceID)

        let savedDeviceID: String?
        do {
            savedDeviceID = try LicenseKeychain.loadDeviceID()
        } catch {
            guard vendorID == nil, let legacyFallback else {
                deviceIdentityResolutionFailed = true
                return nil
            }
            cachedDeviceID = legacyFallback
            return legacyFallback
        }

        if let savedDeviceID {
            cachedDeviceID = savedDeviceID
            defaults.set(savedDeviceID, forKey: fallbackDeviceIDStorage)
            return savedDeviceID
        }

        // The legacy fallback was only authoritative when IDFV was unavailable.
        // Do not let an old backup override a newly available IDFV.
        let candidate = vendorID ?? legacyFallback ?? UUID().uuidString
        do {
            try LicenseKeychain.saveDeviceID(candidate)
        } catch {
            guard vendorID == nil, let legacyFallback else {
                // Never mint a new identity when Keychain access is unavailable.
                deviceIdentityResolutionFailed = true
                return nil
            }
            cachedDeviceID = legacyFallback
            return legacyFallback
        }
        defaults.set(candidate, forKey: fallbackDeviceIDStorage)
        cachedDeviceID = candidate
        return candidate
    }

    private static func nonEmptyDeviceID(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func parseServerDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func messageKey(for code: String) -> String {
        switch code {
        case "paused": return "license.error.paused"
        case "revoked": return "license.error.revoked"
        case "expired": return "license.error.expired"
        case "invalid", "not_found": return "license.error.invalid"
        case "device_mismatch": return "license.error.device"
        case "session_released": return "license.error.released"
        case "session_required": return "license.error.resume"
        default: return "license.error.denied"
        }
    }

    private static let iPhoneModels: [String: String] = [
        "10,1": "iPhone 8", "10,4": "iPhone 8",
        "10,2": "iPhone 8 Plus", "10,5": "iPhone 8 Plus",
        "10,3": "iPhone X", "10,6": "iPhone X",
        "11,2": "iPhone XS", "11,4": "iPhone XS Max", "11,6": "iPhone XS Max",
        "11,8": "iPhone XR",
        "12,1": "iPhone 11", "12,3": "iPhone 11 Pro", "12,5": "iPhone 11 Pro Max",
        "13,1": "iPhone 12 mini", "13,2": "iPhone 12", "13,3": "iPhone 12 Pro", "13,4": "iPhone 12 Pro Max",
        "14,2": "iPhone 13 Pro", "14,3": "iPhone 13 Pro Max", "14,4": "iPhone 13 mini",
        "14,5": "iPhone 13", "14,6": "iPhone SE (3rd generation)",
        "14,7": "iPhone 14", "14,8": "iPhone 14 Plus",
        "15,2": "iPhone 14 Pro", "15,3": "iPhone 14 Pro Max",
        "15,4": "iPhone 15", "15,5": "iPhone 15 Plus",
        "16,1": "iPhone 15 Pro", "16,2": "iPhone 15 Pro Max",
        "17,1": "iPhone 16 Pro", "17,2": "iPhone 16 Pro Max", "17,3": "iPhone 16", "17,4": "iPhone 16 Plus", "17,5": "iPhone 16e",
        "18,1": "iPhone 17 Pro", "18,2": "iPhone 17 Pro Max", "18,3": "iPhone 17", "18,4": "iPhone Air", "18,5": "iPhone 17e",
        "19,2": "iPhone 18 Pro", "19,3": "iPhone 18 Pro Max", "19,4": "iPhone Duo", "19,7": "iPhone 18 Pro Max"
    ]
}

private enum LicenseKeychain {
    private static let service = "com.qingtang.3106.supabase.license"
    private static let account = "activation-key"
    private static let deviceIDAccount = "bound-device-id"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(identity as CFDictionary)
        var item = identity
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LicenseKeychainError.saveFailed(status)
        }
    }

    static func loadDeviceID() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceIDAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LicenseKeychainError.invalidDeviceID
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw LicenseKeychainError.loadFailed(status)
        }
    }

    static func saveDeviceID(_ deviceID: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceIDAccount
        ]
        let update: [String: Any] = [
            kSecValueData as String: Data(deviceID.utf8)
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw LicenseKeychainError.saveFailed(updateStatus)
        }

        var item = identity
        item[kSecValueData as String] = Data(deviceID.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw LicenseKeychainError.saveFailed(addStatus)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum LicenseKeychainError: Error {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case invalidDeviceID
}

private struct SupabaseLicenseResponse: Decodable {
    let ok: Bool
    let code: String
    let expiresAt: String?
    let serverNow: String
    let sessionVersion: Int
    let remainingSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case ok, code
        case expiresAt = "expires_at"
        case serverNow = "server_now"
        case sessionVersion = "session_version"
        case remainingSeconds = "remaining_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        code = try container.decode(String.self, forKey: .code)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        serverNow = try container.decode(String.self, forKey: .serverNow)
        sessionVersion = try container.decode(Int.self, forKey: .sessionVersion)
        remainingSeconds = try container.decodeIfPresent(Double.self, forKey: .remainingSeconds)
    }
}

private struct SupabasePatchEventResponse: Decodable {
    let ok: Bool
    let code: String
}

struct LicenseActivationView: View {
    @Environment(\.appLanguage) private var language
    @FocusState private var keyFieldFocused: Bool
    @State private var key = ""
    @State private var isLoading = false
    @State private var messageKey: String?
    @State private var isKeyVisible = false

    let sessionNotice: String?
    let isRestoring: Bool
    let onActivate: (String) async -> LicenseActivationResult

    private var canActivate: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    activationShell
                        .frame(maxWidth: 360)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height, alignment: .center)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var activationShell: some View {
        VStack(alignment: .leading, spacing: 0) {
            systemHeader
            activityBanner
                .padding(.top, 14)
            if isRestoring {
                restorationStatus
                    .padding(.top, 18)
            } else {
                activationContent
            }
            sessionFooter
        }
        .padding(16)
        .background(
            Color(red: 0.095, green: 0.095, blue: 0.102),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.52), lineWidth: 1)
        }
        .shadow(color: .white.opacity(0.16), radius: 24, y: 0)
        .shadow(color: .black.opacity(0.80), radius: 34, y: 18)
    }

    private var restorationStatus: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.12)
            Text("RESTORING SAVED SESSION")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.92))
            Text("Checking your license on this previously linked device.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 26)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Restoring saved license on the previously linked device")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var systemHeader: some View {
        HStack(spacing: 8) {
            AppLogo(size: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text("FAX AURA")
                    .font(.system(size: 17, weight: .black, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text("PRIVATE CONTROL CENTER")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.05)
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Circle()
                    .fill(.white)
                    .frame(width: 8, height: 8)
                    .shadow(color: .white.opacity(0.75), radius: 5)
                Text(isLoading || isRestoring ? "SYSTEM VERIFYING" : "SYSTEM READY")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.55)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityBanner: some View {
        ZStack(alignment: .bottomLeading) {
            Image("ActivityHeaderArt")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.12), .black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("FAX AURA")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .tracking(0.2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 4)
                Text("SECURE ACTIVATION PANEL")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.85)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(2.8, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.64), lineWidth: 1)
        }
        .shadow(color: .white.opacity(0.12), radius: 11, y: 2)
    }

    private var activationContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WELCOME BACK")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.7)
                        .foregroundStyle(.white.opacity(0.85))

                    Text("Enter your key")
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text("Unlock your private Fax Aura session.")
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.54))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 25, height: 25)
                    .background(.white.opacity(0.92), in: Circle())
                    .shadow(color: .white.opacity(0.2), radius: 8)
                    .padding(.top, 31)
                    .accessibilityHidden(true)
            }
            .padding(.top, 18)

            HStack {
                Text("ACCESS KEY")
                Spacer(minLength: 8)
                Text("SECURE INPUT")
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.05)
            .foregroundStyle(.white.opacity(0.66))
            .padding(.top, 17)

            keyEntry
                .padding(.top, 9)

            initializeButton
                .padding(.top, 13)

            if let feedbackKey = messageKey ?? sessionNotice {
                Label {
                    Text(language.text(feedbackKey))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .padding(.top, 14)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var keyEntry: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20)
                .accessibilityHidden(true)

            keyTextField

            Button {
                isKeyVisible.toggle()
            } label: {
                Image(systemName: isKeyVisible ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: 30, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isKeyVisible ? "Hide access key" : "Show access key")
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Color.white.opacity(0.045), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.55), lineWidth: 1.1)
        }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    @ViewBuilder
    private var keyTextField: some View {
        if isKeyVisible {
            TextField("Enter your key", text: $key)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($keyFieldFocused)
                .onSubmit { submitActivation() }
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .accessibilityLabel("Access key")
        } else {
            SecureField("Enter your key", text: $key)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($keyFieldFocused)
                .onSubmit { submitActivation() }
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .accessibilityLabel("Access key")
        }
    }

    private var initializeButton: some View {
        Button(action: submitActivation) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .tint(.black)
                }

                Text(isLoading ? "VERIFYING…" : "INITIALIZE SESSION")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .tracking(0.15)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 8)

                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(canActivate ? Color.black : Color.white.opacity(0.44))
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                if canActivate {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(white: 0.68)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                } else {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(canActivate ? 0.7 : 0.34), lineWidth: 1)
            }
            .shadow(color: .white.opacity(canActivate ? 0.18 : 0.04), radius: 13, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!canActivate)
        .accessibilityHint("Validates the access key")
    }

    private var sessionFooter: some View {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("PROTECTED SESSION")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.67))
                Spacer(minLength: 8)
                Text("FAX AURA")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.75)
                    .foregroundStyle(.white.opacity(0.8))
            }

            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("PROJECT CREATED BY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.55)
                    .foregroundStyle(.white.opacity(0.53))
                Text("SENSIAURA")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.75)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 18)
    }

    private func submitActivation() {
        guard !isLoading else { return }
        let submittedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedKey.isEmpty else {
            messageKey = "license.error.empty"
            return
        }
        keyFieldFocused = false
        messageKey = nil
        isLoading = true
        Task { @MainActor in
            let result = await onActivate(submittedKey)
            if case .failure(let failureKey) = result {
                messageKey = failureKey
            }
            isLoading = false
        }
    }
}
