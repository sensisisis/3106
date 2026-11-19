import SwiftUI

enum AppTheme {
    static var accent: Color { selectedLEDAccent }
    static var accentSecondary: Color {
        guard UserDefaults.standard.bool(forKey: "faxAura.ledLightingEnabled") else {
            return Color(white: 0.62)
        }
        return selectedLEDAccent.opacity(0.72)
    }
    static let pageBackground = Color.black
    static let consoleBackground = Color(white: 0.045)
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [selectedLEDAccent, selectedLEDAccent.opacity(0.42)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    static let pageInset: CGFloat = 12
    static let rowIconSize: CGFloat = 15
    static let rowIconFrame: CGFloat = 26
    static let fileRowIconSize: CGFloat = 15
    static let fileRowIconFrame: CGFloat = 27
    static let fileRowHeight: CGFloat = 54
    static let appIconSize: CGFloat = 32
    static let emptyIconSize: CGFloat = 30
    static let selectionIconSize: CGFloat = 18
    static let contentCardCornerRadius: CGFloat = 14
    static let contentCardInset: CGFloat = 10
    static let contentCardPadding: CGFloat = 12
    static let actionCornerRadius: CGFloat = 10

    private static var selectedLEDAccent: Color {
        guard UserDefaults.standard.bool(forKey: "faxAura.ledLightingEnabled") else { return .white }
        let storedHue = UserDefaults.standard.object(forKey: "faxAura.ledHue") as? Double ?? 0.56
        let storedIntensity = UserDefaults.standard.object(forKey: "faxAura.ledIntensity") as? Double ?? 0.72
        let hue = min(max(storedHue, 0), 1)
        let intensity = min(max(storedIntensity, 0), 1)
        return Color(hue: hue, saturation: 0.86, brightness: 0.42 + intensity * 0.58)
    }
}

struct AppCardBorder: View {
    var body: some View {
        RoundedRectangle(
            cornerRadius: AppTheme.contentCardCornerRadius,
            style: .continuous
        )
        .strokeBorder(
            Color.white.opacity(0.26),
            lineWidth: 0.7
        )
        .accessibilityHidden(true)
    }
}

struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = AppTheme.rowIconSize
    var frameSize: CGFloat = AppTheme.rowIconFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let prompt: String
    let clearLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 36)
        .background(
            Color.white.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
        }
        .padding(.horizontal, AppTheme.pageInset)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct AppLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Image("OptionCardArt")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
            }
            .shadow(color: .white.opacity(0.14), radius: 8, y: 3)
            .accessibilityHidden(true)
    }
}

struct AuraConsoleHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image("ActivityHeaderArt")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            LinearGradient(
                colors: [.black.opacity(0.12), .clear, .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.42), lineWidth: 0.7))
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(.white).frame(width: 6, height: 6)
                        Text("FAX AURA")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.5)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.42), lineWidth: 0.7))
                }
                Spacer()
                Text(title)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.70), lineWidth: 0.9)
        }
        .shadow(color: .white.opacity(0.12), radius: 9, y: 3)
        .accessibilityElement(children: .combine)
    }
}
