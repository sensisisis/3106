import Foundation
import Security
import SwiftUI
import UIKit
import Darwin

private enum LicenseValidationOutcome {
    case active(FirebaseLicenseResponse)
    case rejected(FirebaseLicenseResponse)
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

    private let sessionVersionStorage = "3106.license.session-version"
    private let fallbackDeviceIDStorage = "3106.license.fallback-device-id"
    private let expirationStorage = "3106.license.expires-at"
    private let firebaseDatabaseURL = "https://aimforge-331a9-default-rtdb.firebaseio.com"
    private var validationGeneration = 0
    private var explicitActivationInFlight = false

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
        guard let savedKey = storedKey, !savedKey.isEmpty else {
            guard generation == validationGeneration else { return }
            deauthorize()
            return
        }

        let key = normalized(savedKey)
        guard let sessionVersion = storedSessionVersion(for: key) else {
            guard generation == validationGeneration, !Task.isCancelled else { return }
            deauthorize()
            notice = "license.error.resume"
            return
        }

        let outcome = await validate(key, sessionVersion: sessionVersion, claim: false)
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
            } else if ["revoked", "invalid", "expired", "session_released", "device_mismatch"].contains(code) {
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
        claim: Bool
    ) async -> LicenseValidationOutcome {
        _ = sessionVersion
        _ = claim

        let key = normalized(key)
        guard isSafeFirebaseKey(key),
              let url = firebaseLicenseURL(for: key) else {
            return .rejected(makeResponse(ok: false, code: "invalid", expiration: nil))
        }

        for _ in 0..<3 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("true", forHTTPHeaderField: "X-Firebase-ETag")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    return .transportFailure("license.error.network")
                }

                let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                guard var record = value as? [String: Any] else {
                    return .rejected(makeResponse(ok: false, code: "invalid", expiration: nil))
                }

                let expiration = firebaseExpiration(record["expiration"])
                let status = (record["status"] as? String)?.uppercased()
                if status == "REVOKED" {
                    return .rejected(makeResponse(ok: false, code: "revoked", expiration: expiration))
                }
                if let expiration, expiration <= Date() {
                    return .rejected(makeResponse(ok: false, code: "expired", expiration: expiration))
                }

                let boundDeviceValue = record["hwid"] as? String
                let boundDevice = boundDeviceValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let boundDevice, !boundDevice.isEmpty {
                    guard boundDevice == deviceID else {
                        return .rejected(makeResponse(ok: false, code: "device_mismatch", expiration: expiration))
                    }
                    return .active(makeResponse(ok: true, code: "active", expiration: expiration))
                }

                guard let etag = http.value(forHTTPHeaderField: "ETag") else {
                    return .transportFailure("license.error.network")
                }
                record["hwid"] = deviceID
                record["lastUsedAt"] = Int(Date().timeIntervalSince1970 * 1_000)

                var claimRequest = URLRequest(url: url)
                claimRequest.httpMethod = "PUT"
                claimRequest.timeoutInterval = 20
                claimRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                claimRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                claimRequest.setValue(etag, forHTTPHeaderField: "If-Match")
                claimRequest.httpBody = try JSONSerialization.data(withJSONObject: record, options: [])

                let (_, claimResponse) = try await URLSession.shared.data(for: claimRequest)
                guard let claimHTTP = claimResponse as? HTTPURLResponse else {
                    return .transportFailure("license.error.network")
                }
                if claimHTTP.statusCode == 412 {
                    continue
                }
                guard (200..<300).contains(claimHTTP.statusCode) else {
                    return .transportFailure("license.error.network")
                }
                return .active(makeResponse(ok: true, code: "active", expiration: expiration))
            } catch is CancellationError {
                return .transportFailure("license.error.cancelled")
            } catch {
                return .transportFailure("license.error.network")
            }
        }

        return .transportFailure("license.error.network")
    }

    private func firebaseLicenseURL(for key: String) -> URL? {
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            return nil
        }
        return URL(string: "\(firebaseDatabaseURL)/keys/\(encodedKey).json")
    }

    private func isSafeFirebaseKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.count <= 128 else { return false }
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return key.rangeOfCharacter(from: allowedCharacters.inverted) == nil
    }

    private func firebaseExpiration(_ value: Any?) -> Date? {
        if let string = value as? String {
            if string.uppercased() == "PERMANENTE" { return nil }
            guard let milliseconds = Double(string) else { return nil }
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        return nil
    }

    private func makeResponse(
        ok: Bool,
        code: String,
        expiration: Date?
    ) -> FirebaseLicenseResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        return FirebaseLicenseResponse(
            ok: ok,
            code: code,
            expiresAt: expiration.map { formatter.string(from: $0) },
            serverNow: formatter.string(from: now),
            sessionVersion: 1,
            remainingSeconds: expiration.map { $0.timeIntervalSince(now) }
        )
    }

    private func persistSession(
        key: String,
        response: FirebaseLicenseResponse,
        preserveExpiration: Bool = false
    ) -> Bool {
        guard storeKeyIfNeeded(key) else { return false }
        UserDefaults.standard.set(response.sessionVersion, forKey: sessionVersionStorage)
        persistExpiration(from: response, preserveExisting: preserveExpiration)
        return true
    }

    private func persistExpiration(
        from response: FirebaseLicenseResponse,
        preserveExisting: Bool
    ) {
        guard let expiresAt = response.expiresAt,
              let expiration = parseServerDate(expiresAt) else {
            if !preserveExisting {
                UserDefaults.standard.removeObject(forKey: expirationStorage)
            }
            return
        }

        let adjustedExpiration: Date
        if let serverNow = parseServerDate(response.serverNow) {
            let localClockSkew = Date().timeIntervalSince1970 - serverNow.timeIntervalSince1970
            adjustedExpiration = expiration.addingTimeInterval(localClockSkew)
        } else {
            adjustedExpiration = expiration
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
        guard let savedKey = storedKey, normalized(savedKey) == normalized(key) else {
            return nil
        }
        return UserDefaults.standard.object(forKey: sessionVersionStorage) as? Int
    }

    private var localExpirationHasPassed: Bool {
        guard let value = UserDefaults.standard.object(forKey: expirationStorage) as? NSNumber else {
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

    private var deviceID: String {
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString,
           !vendorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return vendorID
        }
        let defaults = UserDefaults.standard
        if let fallback = defaults.string(forKey: fallbackDeviceIDStorage), !fallback.isEmpty {
            return fallback
        }
        let fallback = UUID().uuidString
        defaults.set(fallback, forKey: fallbackDeviceIDStorage)
        return fallback
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
        case "invalid": return "license.error.invalid"
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
    private static let service = "com.qingtang.3106.license"
    private static let account = "activation-key"

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
}

private struct FirebaseLicenseResponse {
    let ok: Bool
    let code: String
    let expiresAt: String?
    let serverNow: String
    let sessionVersion: Int
    let remainingSeconds: Double?
}

struct LicenseActivationView: View {
    @Environment(\.appLanguage) private var language
    @FocusState private var keyFieldFocused: Bool
    @State private var key = ""
    @State private var isLoading = false
    @State private var messageKey: String?

    let sessionNotice: String?
    let onActivate: (String) async -> LicenseActivationResult

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.027, blue: 0.035)
                .ignoresSafeArea()
            LinearGradient(
                colors: [Color.black, Color(red: 0.095, green: 0.065, blue: 0.055), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(AppTheme.accent.opacity(0.15))
                .frame(width: 300, height: 300)
                .blur(radius: 90)
                .offset(x: 120, y: -260)
                .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: 22) {
                    brandHeader
                    activationCard
                    footer
                }
                .frame(maxWidth: 410)
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: UIScreen.main.bounds.height * 0.86)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    private var brandHeader: some View {
        VStack(spacing: 15) {
            HStack(spacing: 11) {
                AppLogo(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("3106")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white)
                    Text(language.text("license.brand_subtitle"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(language.text("license.secure_badge"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                }
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            }

            HStack(spacing: 8) {
                Rectangle()
                    .fill(AppTheme.accent.opacity(0.9))
                    .frame(width: 28, height: 2)
                Text(language.text("license.eyebrow"))
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(AppTheme.accent)
                Rectangle()
                    .fill(AppTheme.accent.opacity(0.35))
                    .frame(height: 1)
            }
        }
    }

    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(language.text("license.title"))
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(language.text("license.subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.accent.opacity(0.24), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(language.text("license.key_label"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.55))

                HStack(spacing: 11) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    SecureField(language.text("license.placeholder"), text: $key)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($keyFieldFocused)
                        .onSubmit { submitActivation() }
                        .foregroundStyle(.white)
                        .accessibilityLabel(language.text("license.key_label"))
                }
                .padding(.horizontal, 15)
                .frame(height: 54)
                .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
            }

            Button(action: submitActivation) {
                HStack(spacing: 10) {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "lock.open.fill")
                    }
                    Text(language.text(isLoading ? "license.verifying" : "license.activate"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Spacer()
                    if !isLoading {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 17)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    LinearGradient(
                        colors: [AppTheme.accent, AppTheme.accent.opacity(0.76)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.20), lineWidth: 1))
                .shadow(color: AppTheme.accent.opacity(0.26), radius: 16, y: 7)
            }
            .buttonStyle(.plain)
            .disabled(isLoading || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(isLoading || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0.55)

            if let feedbackKey = messageKey ?? sessionNotice {
                Label {
                    Text(language.text(feedbackKey))
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                }
                .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.58))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.accent.opacity(0.22), lineWidth: 1))
                .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green.opacity(0.9))
                Text(language.text("license.privacy_note"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.095), Color.white.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 23, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.34), radius: 24, y: 12)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(.green.opacity(0.9)).frame(width: 6, height: 6)
            Text(language.text("license.footer"))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
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
