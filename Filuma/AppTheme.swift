import SwiftUI
import Observation
import QuartzCore
import UIKit

// MARK: - Hex helpers

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// A color that resolves differently in light and dark mode.
    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? darkHex : lightHex
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    /// Linear RGB mix — the SwiftUI stand-in for the prototype's
    /// `color-mix(in oklab, …)`. `fraction` is how much of `a` survives.
    static func mix(_ a: UInt32, _ b: UInt32, keeping fraction: Double) -> Color {
        func channel(_ shift: UInt32) -> Double {
            let ca = Double((a >> shift) & 0xFF)
            let cb = Double((b >> shift) & 0xFF)
            return (ca * fraction + cb * (1 - fraction)) / 255
        }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }
}

// MARK: - Hearth accent (Hearthlight design system)

/// The swappable brand hue. Ember is the hearth default; the other three are
/// fully designed alternates surfaced as a user preference in Settings.
enum HearthAccent: String, CaseIterable, Identifiable {
    case ember
    case indigo
    case sage
    case violet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ember: return "Ember"
        case .indigo: return "Indigo"
        case .sage: return "Sage"
        case .violet: return "Violet"
        }
    }

    var baseHex: UInt32 {
        switch self {
        case .ember: return 0xC1571F
        case .indigo: return 0x5A78E0
        case .sage: return 0x3FA372
        case .violet: return 0x8B5AD6
        }
    }

    var color: Color { Color(hex: baseHex) }
    /// Brightest highlight — icon strokes and labels sitting on the accent.
    var hi: Color { .mix(baseHex, 0xFFFFFF, keeping: 0.78) }
    /// Most glow text, active-tab tint, ring highlight.
    var soft: Color { .mix(baseHex, 0xFFFFFF, keeping: 0.52) }
    /// Reserved dark shade.
    var deep: Color { .mix(baseHex, 0x000000, keeping: 0.72) }

    /// Reads the persisted choice without observation — for widget timelines
    /// and other places outside a SwiftUI render pass.
    static var current: HearthAccent {
        let defaults = UserDefaults(suiteName: SharedStore.appGroupId) ?? .standard
        return defaults.string(forKey: HearthTheme.defaultsKey).flatMap(HearthAccent.init) ?? .ember
    }
}

/// Observable accent store. Views read `Color.brand500` (and friends) inside
/// `body`, which routes through this singleton, so changing the hearth hue in
/// Settings re-tints every screen live. Persisted in the App Group so the
/// widgets pick the same hue.
@Observable
final class HearthTheme {
    static let shared = HearthTheme()
    static let defaultsKey = "hearthAccent"

    var accent: HearthAccent {
        didSet {
            let defaults = UserDefaults(suiteName: SharedStore.appGroupId) ?? .standard
            defaults.set(accent.rawValue, forKey: Self.defaultsKey)
            SharedStore.reloadWidgets()
        }
    }

    private init() {
        accent = HearthAccent.current
    }
}

// MARK: - Color Palette (Hearthlight tokens)

extension Color {
    // Brand — derived live from the chosen hearth accent.
    static var brand100: Color { HearthTheme.shared.accent.hi }
    static var brand300: Color { HearthTheme.shared.accent.soft }
    static var brand500: Color { HearthTheme.shared.accent.color }
    static var brand600: Color { .mix(HearthTheme.shared.accent.baseHex, 0x000000, keeping: 0.86) }
    static var brand700: Color { HearthTheme.shared.accent.deep }

    // Semantic — urgency & task contexts (unchanged from the existing app)
    // 4.68:1 against the lightest dark card surface (#232327), so urgency
    // labels remain readable at normal text sizes without losing their warmth.
    static let filumaRed = Color(hex: 0xEF5961)
    static let filumaRedPressed = Color(hex: 0xC93039)
    static let schoolColor = Color(hex: 0x5A78E0)
    static let workColor = Color(hex: 0xE0A020)
    static let personalColor = Color(hex: 0x3FA372)

    // Context display shades — lighter cousins used for text/labels on dark.
    static let schoolDisplay = Color(hex: 0x8FA5EC)
    static let workDisplay = Color(hex: 0xE8BE62)
    static let personalDisplay = Color(hex: 0x6FC49A)

    // Surfaces (Hearthlight is dark-first; light values kept for previews)
    static let filumaBackground = Color(lightHex: 0xF4F4F6, darkHex: 0x0F0F12)
    static let filumaSurface = Color(lightHex: 0xFFFFFF, darkHex: 0x19191D)
    static let filumaSurface2 = Color(lightHex: 0xEAEAEF, darkHex: 0x232327)
    static let filumaSurface3 = Color(lightHex: 0xDEDEE3, darkHex: 0x2E2E33)
    static let filumaText = Color(lightHex: 0x1C1C1E, darkHex: 0xF5F5F7)
    static let filumaSubtle = Color(lightHex: 0x6E6E76, darkHex: 0x9A9AA2)
    /// Ink for bright Hearth and context-filled controls. Unlike the ordinary
    /// foreground token, this stays dark in both appearances so every accent
    /// choice keeps button text legible.
    static let filumaControlInk = Color(hex: 0x0F0F12)
    // Dark value must stay ≥ 4.5:1 against filumaBackground/filumaSurface —
    // filumaFaint is used for real content (timestamps, counts), not decoration.
    static let filumaFaint = Color(lightHex: 0x9A9AA2, darkHex: 0x86868E)

    static let filumaBorder = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.07)
            : UIColor(white: 0, alpha: 0.07)
    })
}

extension TaskContext {
    /// Fill color for bars, dots, and tags.
    var color: Color {
        switch self {
        case .school: return .schoolColor
        case .work: return .workColor
        case .personal: return .personalColor
        }
    }

    /// Text/label shade — brighter than the fill so it reads on dark surfaces.
    var displayColor: Color {
        switch self {
        case .school: return .schoolDisplay
        case .work: return .workDisplay
        case .personal: return .personalDisplay
        }
    }
}

// MARK: - Gradients

extension LinearGradient {
    /// The signature CTA / FAB / toggle fill. The restrained
    /// `accentHi → accentSoft` ramp stays luminous while preserving dark-ink
    /// contrast across every Hearth accent.
    static var hearth: LinearGradient {
        let accent = HearthTheme.shared.accent
        return LinearGradient(
            // Both stops are deliberately light enough for filumaControlInk.
            // The old accentHi -> accent ramp made white labels fail contrast
            // for Indigo and Sage, while dark labels failed on Ember/Violet.
            colors: [accent.hi, accent.soft],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

}

// MARK: - Corner radii

enum FilumaRadius {
    static let sm: CGFloat = 8
    static let row: CGFloat = 14
    static let button: CGFloat = 14
    static let card: CGFloat = 16
    static let group: CGFloat = 18
    static let hero: CGFloat = 22
    static let sheet: CGFloat = 24
}

/// Widths shared by the phone-first surfaces when they grow into an iPad
/// window. Schedule intentionally does not use the readable cap: its timeline
/// earns the extra canvas, while prose and cards are calmer at a human width.
enum FilumaLayout {
    static let readableContentMaxWidth: CGFloat = 760
    static let onboardingContentMaxWidth: CGFloat = 620
    static let tabBarMaxWidth: CGFloat = 620
}

/// A small spacing vocabulary for the repeated Hearthlight rhythms. One-off
/// artwork can still use bespoke geometry; ordinary screens should compose
/// from these steps instead of accumulating near-duplicate magic numbers.
enum FilumaSpacing {
    static let hairline: CGFloat = 4
    static let compact: CGFloat = 8
    static let related: CGFloat = 12
    static let standard: CGFloat = 16
    static let screen: CGFloat = 20
    static let section: CGFloat = 24
    static let chapter: CGFloat = 32
    static let spacious: CGFloat = 40
}

// MARK: - Motion

/// Hearthlight's shared motion vocabulary. Ordinary interface changes settle
/// without bounce; momentum and celebration are the only places that should
/// ever overshoot. Views that travel also need a Reduce Motion fallback.
enum HearthMotion {
    /// Touch release and small control changes.
    static let control = Animation.spring(response: 0.24, dampingFraction: 1)
    /// Selection indicators and compact state changes.
    static let selection = Animation.spring(response: 0.32, dampingFraction: 1)
    /// One-shot materialization for a screen's single explanatory moment.
    static let reveal = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.42)
    /// Non-spatial feedback used when Reduce Motion is enabled.
    static let reduced = Animation.easeOut(duration: 0.16)
}

// MARK: - Typography (Nunito + JetBrains Mono)

struct AppFont {
    /// Display — Nunito ExtraBold
    static func display(_ size: CGFloat = 34) -> Font {
        .custom("Nunito-ExtraBold", size: size, relativeTo: .largeTitle)
    }

    /// Screen titles ("Your Tasks") use the heaviest cut.
    static func title(_ size: CGFloat = 28) -> Font {
        .custom("Nunito-Black", size: size, relativeTo: .title)
    }

    /// Heading — Nunito Bold
    static func heading(_ size: CGFloat = 20) -> Font {
        .custom("Nunito-Bold", size: size, relativeTo: .headline)
    }

    /// Card/list titles — Nunito ExtraBold
    static func cardTitle(_ size: CGFloat = 17) -> Font {
        .custom("Nunito-ExtraBold", size: size, relativeTo: .headline)
    }

    /// Body — Nunito Regular
    static func body(_ size: CGFloat = 16) -> Font {
        .custom("Nunito-Regular", size: size, relativeTo: .body)
    }

    /// Emphasized body — Nunito SemiBold
    static func bodySemibold(_ size: CGFloat = 16) -> Font {
        .custom("Nunito-SemiBold", size: size, relativeTo: .body)
    }

    /// Caption — Nunito Bold
    static func caption(_ size: CGFloat = 13) -> Font {
        .custom("Nunito-Bold", size: size, relativeTo: .caption)
    }

    /// Settings section headers — Nunito ExtraBold
    static func settingsSectionHeader(_ size: CGFloat = 11) -> Font {
        .custom("Nunito-ExtraBold", size: size, relativeTo: .caption2)
    }

    /// Settings row labels — Nunito Bold
    static func settingsRowLabel(_ size: CGFloat = 15) -> Font {
        .custom("Nunito-Bold", size: size, relativeTo: .subheadline)
    }

    /// Numeric/time displays — JetBrains Mono SemiBold
    static func mono(_ size: CGFloat = 14) -> Font {
        .custom("JetBrainsMono-SemiBold", size: size, relativeTo: .body)
    }

    static func monoMedium(_ size: CGFloat = 14) -> Font {
        .custom("JetBrainsMono-Medium", size: size, relativeTo: .body)
    }

    static func monoBold(_ size: CGFloat = 14) -> Font {
        .custom("JetBrainsMono-Bold", size: size, relativeTo: .body)
    }
}

// MARK: - View Modifiers

struct CardModifier: ViewModifier {
    var radius: CGFloat = FilumaRadius.card

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color.filumaSurface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.filumaBorder, lineWidth: 1)
            )
    }
}

struct ContextTagModifier: ViewModifier {
    let context: TaskContext

    func body(content: Content) -> some View {
        content
            .font(AppFont.caption(11))
            .foregroundStyle(context.displayColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(context.color.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(context.color.opacity(0.25), lineWidth: 1))
    }
}

/// Full-width gradient CTA ("Schedule it", "Continue session"…) with the
/// signature hearth glow.
struct PrimaryButtonModifier: ViewModifier {
    var fill: Color? = nil
    var enabled: Bool = true

    func body(content: Content) -> some View {
        let gradient: LinearGradient = {
            if let fill {
                return LinearGradient(
                    colors: [fill, fill],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            return .hearth
        }()
        let glowColor = fill ?? Color.brand500

        return content
            .font(AppFont.heading(16))
            .foregroundStyle(enabled ? Color.filumaControlInk : Color.filumaSubtle)
            .frame(maxWidth: .infinity)
            .padding(.vertical, FilumaSpacing.standard)
            .background(
                RoundedRectangle(cornerRadius: FilumaRadius.button, style: .continuous)
                    .fill(enabled ? AnyShapeStyle(gradient) : AnyShapeStyle(Color.filumaSurface3))
            )
            // A quiet dark rim gives the bright control definition without
            // putting translucent white decoration across every accent.
            .overlay(
                RoundedRectangle(cornerRadius: FilumaRadius.button, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.filumaControlInk.opacity(enabled ? 0.14 : 0),
                                Color.filumaControlInk.opacity(0)
                            ],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: enabled ? glowColor.opacity(0.22) : .clear, radius: 10, y: 4)
    }
}

/// The single most repeated visual signature of Hearthlight: a soft
/// color-matched glow behind anything active or highlighted.
struct HearthGlowModifier: ViewModifier {
    var color: Color
    var radius: CGFloat = 12
    var opacity: Double = 0.4

    func body(content: Content) -> some View {
        content.shadow(color: color.opacity(opacity), radius: radius)
    }
}

/// Immediate touch-down feedback with a critically damped release. Scaling is
/// removed under Reduce Motion, while opacity still confirms the touch.
struct HearthPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    var pressedOpacity: Double = 0.9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            // Touch-down is immediate. Only the release settles, which keeps
            // the control feeling attached to the user's finger.
            .animation(
                configuration.isPressed
                    ? nil
                    : (reduceMotion ? HearthMotion.reduced : HearthMotion.control),
                value: configuration.isPressed
            )
    }
}

extension View {
    func cardStyle(radius: CGFloat = FilumaRadius.card) -> some View {
        modifier(CardModifier(radius: radius))
    }

    func contextTag(_ context: TaskContext) -> some View {
        modifier(ContextTagModifier(context: context))
    }

    func primaryButtonStyle(fill: Color? = nil, enabled: Bool = true) -> some View {
        modifier(PrimaryButtonModifier(fill: fill, enabled: enabled))
    }

    func hearthGlow(_ color: Color, radius: CGFloat = 12, opacity: Double = 0.4) -> some View {
        modifier(HearthGlowModifier(color: color, radius: radius, opacity: opacity))
    }

    func hearthPressStyle(
        scale: CGFloat = 0.97,
        pressedOpacity: Double = 0.9
    ) -> some View {
        buttonStyle(HearthPressButtonStyle(
            pressedScale: scale,
            pressedOpacity: pressedOpacity
        ))
    }
}

// MARK: - Screen title

/// "Your Tasks" / "Schedule" / "Your Weave" — one clear typographic anchor.
/// Accent belongs in the nearby thread, status, or rule rather than inside
/// every display word.
struct HearthTitle: View {
    let text: String
    var size: CGFloat = 30

    var body: some View {
        Text(text)
            .font(AppFont.title(size))
            .foregroundStyle(Color.filumaText)
    }
}

// MARK: - First-thread journey

/// Filuma's smallest honest product diagram: capture a task, let the calendar
/// hold it, then begin. It appears at first launch and again in the virgin
/// Tasks state so the two moments feel like one continuous chapter.
struct HearthThreadJourney: View {
    let isRevealed: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Ellipse()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color.brand500.opacity(0.18), location: 0),
                            .init(color: Color.brand500.opacity(0.07), location: 0.42),
                            .init(color: Color.clear, location: 0.72)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 320, height: 210)
                .blur(radius: 8)

            HStack(spacing: 0) {
                node(icon: "plus", size: 54, delay: 0)
                connector(delay: 0.04)
                node(icon: "calendar", size: 70, delay: 0.08, isPrimary: true)
                connector(delay: 0.12)
                node(icon: "play.fill", size: 54, delay: 0.16)
            }
            .frame(maxWidth: 300)
        }
        .frame(height: 148)
        .accessibilityHidden(true)
    }

    private func node(
        icon: String,
        size: CGFloat,
        delay: Double,
        isPrimary: Bool = false
    ) -> some View {
        ZStack {
            Circle()
                .fill(Color.filumaSurface)
            Circle()
                .stroke(
                    isPrimary ? Color.brand300.opacity(0.55) : Color.brand500.opacity(0.28),
                    lineWidth: 1
                )
            if isPrimary {
                Circle()
                    .stroke(Color.brand500.opacity(0.2), lineWidth: 7)
                    .blur(radius: 7)
            }
            Image(systemName: icon)
                .font(.system(size: isPrimary ? 24 : 18, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.brand100 : Color.brand300)
        }
        .frame(width: size, height: size)
        .hearthGlow(.brand500, radius: isPrimary ? 18 : 10, opacity: isPrimary ? 0.34 : 0.18)
        .scaleEffect(reduceMotion ? 1 : (isRevealed ? 1 : 0.84))
        .opacity(isRevealed ? 1 : 0)
        .animation(revealAnimation(delay: delay), value: isRevealed)
    }

    private func connector(delay: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.brand500.opacity(0.12))
                .frame(height: 2)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.brand300, Color.brand500],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2)
                .blur(radius: 0.4)
        }
        .frame(width: 56, height: 12)
        .scaleEffect(x: reduceMotion ? 1 : (isRevealed ? 1 : 0), anchor: .leading)
        .opacity(isRevealed ? 1 : 0)
        .animation(revealAnimation(delay: delay), value: isRevealed)
    }

    private func revealAnimation(delay: Double) -> Animation {
        reduceMotion ? HearthMotion.reduced : HearthMotion.reveal.delay(delay)
    }
}

// MARK: - Ambient hearth background

/// Rising ember particles — the hearth is always faintly alive. A UIKit-hosted
/// `CAEmitterLayer` keeps the animated field smooth, while Reduce Motion swaps
/// in a deterministic, completely static Canvas rendering.
struct EmberField: View {
    var emberCount: Int = 16
    var intensity: Double = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(emberCount: Int = 16, intensity: Double = 1.0) {
        self.emberCount = emberCount
        self.intensity = intensity
    }

    var body: some View {
        let accent = HearthTheme.shared.accent

        Group {
            if reduceMotion {
                StaticEmberCanvas(
                    emberCount: emberCount,
                    intensity: intensity,
                    accent: accent
                )
            } else {
                EmberEmitterView(
                    emberCount: emberCount,
                    intensity: intensity,
                    accent: accent,
                    sceneIsActive: scenePhase == .active
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct StaticEmberCanvas: View {
    let emberCount: Int
    let intensity: Double
    let accent: HearthAccent

    var body: some View {
        Canvas { context, size in
            for index in 0..<max(0, emberCount) {
                let family = (index * 7) % 20
                let x = unitValue(index, salt: 17) * 0.94 + 0.03
                let y = unitValue(index, salt: 53) * 0.9 + 0.05
                let scale = 0.8 + unitValue(index, salt: 89) * 0.4

                let baseSize: Double
                let baseAlpha: Double
                let coreColor: Color
                if family < 14 {
                    baseSize = 6.5
                    baseAlpha = 0.4
                    coreColor = accent.color
                } else if family < 19 {
                    baseSize = 4.2
                    baseAlpha = 0.6
                    coreColor = accent.soft
                } else {
                    baseSize = 3.2
                    baseAlpha = 0.9
                    coreColor = accent.hi
                }

                let alpha = min(1, max(0, baseAlpha * intensity))
                guard alpha > 0.01 else { continue }

                let particleSize = baseSize * scale
                let center = CGPoint(x: x * size.width, y: y * size.height)
                let rect = CGRect(
                    x: center.x - particleSize / 2,
                    y: center.y - particleSize / 2,
                    width: particleSize,
                    height: particleSize
                )

                context.opacity = alpha * 0.32
                context.fill(
                    Path(ellipseIn: rect.insetBy(dx: -particleSize, dy: -particleSize)),
                    with: .color(accent.color)
                )
                context.opacity = alpha
                context.fill(Path(ellipseIn: rect), with: .color(coreColor))
            }
        }
    }

    /// Stable integer mixing keeps Reduce Motion layouts identical every time.
    private func unitValue(_ index: Int, salt: UInt64) -> Double {
        var value = UInt64(truncatingIfNeeded: index) &+ salt &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value & 0x00FF_FFFF) / Double(0x0100_0000)
    }
}

private struct EmberEmitterView: UIViewRepresentable {
    let emberCount: Int
    let intensity: Double
    let accent: HearthAccent
    let sceneIsActive: Bool

    func makeUIView(context: Context) -> EmberEmitterUIView {
        // Configuration starts here rather than in `onAppear`: EmberField lives
        // inside `.background(...)`, where SwiftUI does not reliably deliver
        // appearance callbacks.
        EmberEmitterUIView(
            emberCount: emberCount,
            intensity: intensity,
            accent: accent,
            sceneIsActive: sceneIsActive
        )
    }

    func updateUIView(_ uiView: EmberEmitterUIView, context: Context) {
        uiView.update(
            emberCount: emberCount,
            intensity: intensity,
            accent: accent,
            sceneIsActive: sceneIsActive
        )
    }
}

private final class EmberEmitterUIView: UIView {
    /// Deliberately a sublayer, NOT the view's backing layer: SwiftUI writes
    /// to hosted views' backing layers on every commit of the surrounding
    /// hierarchy, and every external property write on a CAEmitterLayer
    /// restarts its particle simulation — the field stayed permanently
    /// "just born". A private sublayer is only ever touched by this view.
    private let emitter = CAEmitterLayer()
    private var emberCount: Int
    private var intensity: Double
    private var accent: HearthAccent
    private var sceneIsActive: Bool
    private var configuredSize = CGSize.zero
    private var hasInstalledCells = false

    private static let particleImage: CGImage = {
        let size = CGSize(width: 28, height: 28)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let glow = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    UIColor.white.withAlphaComponent(0.98).cgColor,
                    UIColor.white.withAlphaComponent(0.58).cgColor,
                    UIColor.white.withAlphaComponent(0.16).cgColor,
                    UIColor.clear.cgColor
                ] as CFArray,
                locations: [0, 0.16, 0.48, 1]
            )!
            context.drawRadialGradient(
                glow,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: size.width / 2,
                options: .drawsAfterEndLocation
            )

            let hotSpotCenter = CGPoint(x: center.x - 3, y: center.y - 2)
            let hotSpot = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    UIColor.white.withAlphaComponent(0.9).cgColor,
                    UIColor.white.withAlphaComponent(0.24).cgColor,
                    UIColor.clear.cgColor
                ] as CFArray,
                locations: [0, 0.38, 1]
            )!
            context.drawRadialGradient(
                hotSpot,
                startCenter: hotSpotCenter,
                startRadius: 0,
                endCenter: hotSpotCenter,
                endRadius: 5.5,
                options: .drawsAfterEndLocation
            )
        }.cgImage!
    }()

    init(
        emberCount: Int,
        intensity: Double,
        accent: HearthAccent,
        sceneIsActive: Bool
    ) {
        self.emberCount = emberCount
        self.intensity = intensity
        self.accent = accent
        self.sceneIsActive = sceneIsActive
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(emitter)
        emitter.renderMode = .additive
        // A thin rectangle spanning the bottom edge, NOT `.line`: line-shaped
        // emitters pinned particles to the line and ignored cell velocity in
        // every mode we tried (verified empirically on iOS 18 sim, 2026-07).
        // Rectangle + `.volume` honors emissionLongitude (-π/2 = up).
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .volume
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Only touch the layer when geometry actually changed: ANY property
        // write on a CAEmitterLayer restarts its whole particle simulation at
        // the next commit, and SwiftUI re-lays-out this view on every screen
        // body re-evaluation (e.g. the 1s hero countdown tick) — writing
        // unconditionally kept resetting the field to freshly-born particles.
        guard bounds.size != configuredSize, bounds.width > 0, bounds.height > 0 else { return }
        configuredSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.maxY + 8)
        emitter.emitterSize = CGSize(width: bounds.width, height: 14)
        rebuildCells()
        CATransaction.commit()
        updatePlaybackState()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlaybackState()
    }

    func update(
        emberCount: Int,
        intensity: Double,
        accent: HearthAccent,
        sceneIsActive: Bool
    ) {
        let needsRebuild = self.emberCount != emberCount
            || self.intensity != intensity
            || self.accent != accent

        self.emberCount = emberCount
        self.intensity = intensity
        self.accent = accent
        self.sceneIsActive = sceneIsActive

        if needsRebuild, bounds.width > 0, bounds.height > 0 {
            rebuildCells()
        }
        updatePlaybackState()
    }

    private func rebuildCells() {
        let height = bounds.height
        let count = Double(max(0, emberCount))
        let strength = max(0, intensity)

        emitter.emitterCells = [
            makeCell(
                name: "drifting",
                share: 0.70,
                totalCount: count,
                lifetime: 50,
                scale: 0.26,
                alpha: min(1, 0.4 * strength),
                color: UIColor(accent.color),
                height: height,
                emissionRange: 0.14,
                spinRange: 0.22
            ),
            makeCell(
                name: "hot",
                share: 0.25,
                totalCount: count,
                lifetime: 45,
                scale: 0.16,
                alpha: min(1, 0.6 * strength),
                color: UIColor(accent.soft),
                height: height,
                emissionRange: 0.11,
                spinRange: 0.3
            ),
            makeCell(
                name: "spark",
                share: 0.05,
                totalCount: count,
                lifetime: 28,
                scale: 0.12,
                alpha: min(1, 0.9 * strength),
                color: UIColor(accent.hi),
                height: height,
                emissionRange: 0.09,
                spinRange: 0.38
            )
        ]

        if !hasInstalledCells {
            hasInstalledCells = true
            emitter.beginTime = CACurrentMediaTime() - 50
        }
    }

    private func makeCell(
        name: String,
        share: Double,
        totalCount: Double,
        lifetime: Double,
        scale: CGFloat,
        alpha: Double,
        color: UIColor,
        height: CGFloat,
        emissionRange: CGFloat,
        spinRange: CGFloat
    ) -> CAEmitterCell {
        let cell = CAEmitterCell()
        let accelerationFraction = 0.18
        let velocity = height / lifetime * (1 - accelerationFraction / 2)

        cell.name = name
        cell.contents = Self.particleImage
        cell.contentsScale = 1
        cell.birthRate = Float(totalCount * share / lifetime)
        cell.lifetime = Float(lifetime)
        cell.lifetimeRange = Float(lifetime * 0.12)
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = emissionRange
        cell.velocity = velocity
        cell.velocityRange = velocity * 0.28
        cell.yAcceleration = -height * accelerationFraction / (lifetime * lifetime)
        cell.scale = scale
        cell.scaleRange = scale * 0.34
        cell.scaleSpeed = -scale / CGFloat(lifetime) * 0.18
        cell.alphaRange = Float(alpha * 0.18)
        cell.alphaSpeed = Float(-alpha / lifetime * 0.65)
        cell.spinRange = spinRange
        cell.color = color.withAlphaComponent(alpha).cgColor
        return cell
    }

    private func updatePlaybackState() {
        // With no cells there is nothing to animate. Waiting until the first
        // layout also lets the initial -50s beginTime become the paused offset.
        guard hasInstalledCells else { return }

        let shouldPause = !sceneIsActive || window == nil
        if shouldPause, emitter.speed != 0 {
            let pausedTime = emitter.convertTime(CACurrentMediaTime(), from: nil)
            emitter.speed = 0
            emitter.timeOffset = pausedTime
        } else if !shouldPause, emitter.speed == 0 {
            let pausedTime = emitter.timeOffset
            emitter.speed = 1
            emitter.timeOffset = 0
            emitter.beginTime = 0
            let now = emitter.convertTime(CACurrentMediaTime(), from: nil)
            emitter.beginTime = now - pausedTime
        }
    }
}

/// The standard Hearthlight screen backdrop: near-black canvas, a restrained
/// header haze, one warmer held-light field below, and a sparse ember trace.
/// Content remains the event; local focal objects may carry the stronger glow.
struct HearthScreenBackground: View {
    var topGlow: Double = 0.10
    var bottomGlow: Double = 0.20
    var embers: Int = 10
    var emberIntensity: Double = 1.0

    var body: some View {
        ZStack {
            Color.filumaBackground

            RadialGradient(
                stops: [
                    .init(color: Color.brand500.opacity(min(topGlow, 0.10)), location: 0),
                    .init(color: Color.brand500.opacity(min(topGlow, 0.10) * 0.18), location: 0.48),
                    .init(color: .clear, location: 0.75)
                ],
                center: UnitPoint(x: 0.5, y: -0.1),
                startRadius: 0,
                endRadius: 340
            )

            RadialGradient(
                stops: [
                    .init(color: Color.brand500.opacity(min(bottomGlow, 0.20)), location: 0),
                    .init(color: Color.brand500.opacity(min(bottomGlow, 0.20) * 0.20), location: 0.52),
                    .init(color: .clear, location: 0.75)
                ],
                center: UnitPoint(x: 0.5, y: 1.06),
                startRadius: 0,
                endRadius: 380
            )

            EmberField(
                emberCount: min(embers, 10),
                intensity: min(emberIntensity, 0.75)
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Wraps a screen in the hearth backdrop.
    func hearthScreen(
        topGlow: Double = 0.10,
        bottomGlow: Double = 0.20,
        embers: Int = 10,
        emberIntensity: Double = 1.0
    ) -> some View {
        background(HearthScreenBackground(
            topGlow: topGlow,
            bottomGlow: bottomGlow,
            embers: embers,
            emberIntensity: emberIntensity
        ))
    }
}

// MARK: - Progress ring

/// The held flame: a conic progress arc in accentSoft→accent with a blurred
/// glow duplicate behind it. Used at 74pt on the home hero and 200pt in the
/// work session. Progress past 1 loops: the completed lap stays as a full,
/// slightly banked ring underneath while the overflow arc burns a fresh lap
/// over it.
struct HearthProgressRing: View {
    /// Completed fraction. Values above 1 draw a second lap over the full ring.
    var progress: Double
    var size: CGFloat
    var lineWidth: CGFloat
    /// Extra pulsing halo behind the ring (work session only).
    var showsHalo: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var isLooping: Bool { progress > 1 }

    /// The fraction the leading arc draws this lap.
    private var lapFraction: Double {
        guard isLooping else { return min(1, max(0.003, progress)) }
        let wrapped = progress.truncatingRemainder(dividingBy: 1)
        return max(0.003, wrapped)
    }

    var body: some View {
        let accent = HearthTheme.shared.accent
        let arcGradient = AngularGradient(
            colors: [accent.soft, accent.color, accent.color],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * lapFraction)
        )

        ZStack {
            if showsHalo {
                // Two pulsing layers: a wide soft corona and a tighter core,
                // so the held flame reads as burning rather than tinted.
                Circle()
                    .fill(accent.color.opacity(0.3))
                    .frame(width: size * 1.32, height: size * 1.32)
                    .blur(radius: size * 0.16)
                    .scaleEffect(breathing ? 1.09 : 0.92)
                Circle()
                    .fill(accent.color.opacity(0.2))
                    .frame(width: size * 1.12, height: size * 1.12)
                    .blur(radius: size * 0.08)
                    .scaleEffect(breathing ? 1.05 : 0.96)
            }

            // Track
            Circle()
                .stroke(Color.filumaBorder, lineWidth: lineWidth)
                .frame(width: size, height: size)

            // The finished lap, banked: the block's worth of work is done and
            // the flame keeps going over it.
            if isLooping {
                Circle()
                    .stroke(accent.color.opacity(0.45), lineWidth: lineWidth)
                    .frame(width: size, height: size)
            }

            // Glow duplicate under the arc — breathes like the prototype's
            // `animation: breathe` on the blurred conic layer.
            arc(arcGradient)
                .blur(radius: lineWidth * 0.9)
                .opacity(showsHalo && !reduceMotion ? (breathing ? 1.0 : 0.55) : 0.8)

            arc(arcGradient)
        }
        .onAppear(perform: startBreathingIfNeeded)
        // `showsHalo` is live (running/paused, upcoming/active): a ring that
        // appears idle must start breathing the moment its flame is held,
        // and restart cleanly after a pause interrupted the repeat-forever.
        .onChange(of: showsHalo) { _, _ in startBreathingIfNeeded() }
        // Purely decorative: callers pair this with a text label/value and
        // combine the accessibility element there.
        .accessibilityHidden(true)
    }

    /// Breathing runs only while the halo shows — idle rings sit still (a
    /// blurred layer animating forever on every list row was a battery tax).
    private func startBreathingIfNeeded() {
        guard showsHalo && !reduceMotion else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { breathing = false }
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }

    private func arc(_ style: AngularGradient) -> some View {
        Circle()
            .trim(from: 0, to: lapFraction)
            .stroke(style, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: size, height: size)
    }
}

// MARK: - Breathing dot

/// The small living dot used on the "now" line, session status, and active
/// cards. Sits still under Reduce Motion.
struct BreathingDot: View {
    var color: Color
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .hearthGlow(color, radius: size, opacity: 0.7)
            .scaleEffect(breathing ? 1.18 : 0.88)
            .opacity(breathing ? 1 : 0.75)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Hearth toggle

/// Capsule switch with an accent-gradient, glowing track when on.
/// Honors `.labelsHidden()`, which built-in styles get for free but custom
/// styles must read from the environment.
struct HearthToggleStyle: ToggleStyle {
    @Environment(\.labelsVisibility) private var labelsVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            if reduceMotion {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    configuration.isOn.toggle()
                }
            } else {
                withAnimation(HearthMotion.selection) {
                    configuration.isOn.toggle()
                }
            }
        } label: {
            HStack {
                if labelsVisibility != .hidden {
                    configuration.label
                    Spacer(minLength: 8)
                }
                Capsule()
                    .fill(
                        configuration.isOn
                            ? AnyShapeStyle(LinearGradient.hearth)
                            : AnyShapeStyle(Color.filumaSurface3)
                    )
                    .frame(width: 46, height: 28)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(
                                configuration.isOn
                                    ? Color.filumaControlInk
                                    : Color.filumaSubtle
                            )
                            .frame(width: 22, height: 22)
                            .padding(3)
                    }
                    .shadow(
                        color: configuration.isOn ? Color.brand500.opacity(0.45) : .clear,
                        radius: 8
                    )
            }
            // The label owns the real target. Framing only the synthesized
            // Button host leaves accessibility focused on the 46x28 artwork.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Keep the 46x28 artwork, but make the control itself meet Apple's
        // minimum comfortable target and expose native switch semantics to
        // assistive technologies instead of presenting as an unlabeled button.
        .frame(minWidth: 44, minHeight: 44)
        // Native UISwitch artwork exposes an intrinsic 46x28 accessibility
        // leaf even when its layout wrapper is taller. Promote the real 44pt
        // Hearth control instead, then explicitly retain native toggle role,
        // label, and value semantics.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel { _ in
            configuration.label
        }
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - Shared components

/// Icon-in-circle + heading + subtext (+ optional ghost CTA) empty-state pattern.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    var actionIdentifier: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.brand500.opacity(0.1))
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.brand300)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 6)

            Text(title)
                .font(AppFont.heading(16))
                .foregroundStyle(Color.filumaText)
            Text(subtitle)
                .font(AppFont.body(13))
                .foregroundStyle(Color.filumaSubtle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)

            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(AppFont.caption(13))
                        .foregroundStyle(Color.brand300)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        // Put the minimum on the label itself: SwiftUI's
                        // synthesized Button accessibility host otherwise
                        // reports only the text/padding artwork (about 36pt).
                        .frame(minHeight: 44)
                        .overlay(Capsule().stroke(Color.brand500.opacity(0.4), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .hearthPressStyle(scale: 0.97, pressedOpacity: 0.86)
                .frame(minHeight: 44)
                .padding(.top, 10)
                .accessibilityIdentifier(actionIdentifier ?? actionLabel)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FilumaSpacing.spacious)
        .padding(.horizontal, FilumaSpacing.section)
    }
}

/// Inline info banner (e.g. "Replanned 2 missed blocks").
struct InfoBanner: View {
    let icon: String
    let text: String
    var tint: Color = .schoolDisplay

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(AppFont.body(13))
                .foregroundStyle(Color.filumaText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FilumaSpacing.standard)
        .padding(.vertical, FilumaSpacing.related)
        .background(Color.filumaSurface)
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FilumaRadius.row, style: .continuous)
                .stroke(Color.filumaBorder, lineWidth: 1)
        )
    }
}

// MARK: - Countdown Formatting

struct CountdownFormatter {
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static func string(from now: Date, to target: Date) -> String {
        let interval = target.timeIntervalSince(now)
        if interval < 0 {
            return "overdue"
        }

        let minutes = Int(interval) / 60
        let hours = minutes / 60
        let days = hours / 24

        if days > 0 {
            return days == 1 ? "in 1 day" : "in \(days) days"
        } else if hours > 0 {
            return hours == 1 ? "in 1 hour" : "in \(hours) hours"
        } else if minutes > 0 {
            return minutes == 1 ? "in 1 min" : "in \(minutes) min"
        } else {
            return "now"
        }
    }

    static func deadlineString(from now: Date, to deadline: Date) -> String {
        let interval = deadline.timeIntervalSince(now)
        if interval < 0 {
            return "Past due"
        }

        let hours = Int(interval) / 3600
        let days = hours / 24

        if days > 7 {
            return "Due \(monthDayFormatter.string(from: deadline))"
        } else if days > 0 {
            return days == 1 ? "Due tomorrow" : "Due in \(days) days"
        } else if hours > 0 {
            return hours == 1 ? "Due in 1 hour" : "Due in \(hours) hours"
        } else {
            return "Due very soon"
        }
    }

    static func effortString(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        } else {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
    }

    static func timerString(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Time formatting

struct TimeFormatter {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static let dayOfWeek: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}
