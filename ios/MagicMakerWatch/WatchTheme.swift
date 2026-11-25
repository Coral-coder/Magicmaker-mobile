import SwiftUI

// The watch look (docs/WATCH_APP.md 5.4): black background, monospaced uppercase text and the
// five VFD inks of the iPhone's VFD base colour, which the iPhone sends with every context.
// Nothing is filled except "inverted" blocks (busy rows, the STOP button, red-base alarms).

extension Color {
    /// "#RRGGBB" (leading # optional); black for anything else.
    init(watchHex: String) {
        var digits: String = watchHex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        let value: UInt32 = digits.count == 6 ? (UInt32(digits, radix: 16) ?? 0) : 0
        self.init(red: Double((value >> 16) & 0xFF) / 255.0,
                  green: Double((value >> 8) & 0xFF) / 255.0,
                  blue: Double(value & 0xFF) / 255.0)
    }
}

/// The inks of one theme. Always-on (luminance reduced) draws them at 50 %.
struct WatchInk {
    let highlight: Color
    let text: Color
    let dim: Color
    let alarm: Color
    /// A red-ish base: alarms are drawn as inverted highlight blocks, as on the iPhone's VFD.
    let alarmInverted: Bool

    init(_ theme: WatchThemeColors, reduced: Bool = false) {
        let level: Double = reduced ? 0.5 : 1.0
        highlight = Color(watchHex: theme.highlight).opacity(level)
        text = Color(watchHex: theme.text).opacity(level)
        dim = Color(watchHex: theme.dim).opacity(level)
        alarm = Color(watchHex: theme.alarm).opacity(level)
        alarmInverted = theme.alarmInverted
    }

    /// The fill of an alarm block (the STOP button): alarm, or highlight on a red-ish base.
    var alarmFill: Color {
        alarmInverted ? highlight : alarm
    }
}

/// Fixed sizes that fit 40 mm (162 pt wide) to 49 mm (205 pt wide).
enum WatchFont {
    static let title: Font = Font.system(size: 15, weight: .semibold, design: .monospaced)
    static let body: Font = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let small: Font = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let smallBold: Font = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let hero: Font = Font.system(size: 24, weight: .bold, design: .monospaced)
}

/// Which ink a line is drawn in.
enum WatchTone {
    case highlight
    case text
    case dim
    case alarm
}

/// Draws content in one ink. Alarm on a red-ish base is black on a highlight block.
struct WatchToneStyle: ViewModifier {
    let tone: WatchTone
    let ink: WatchInk

    @ViewBuilder
    func body(content: Content) -> some View {
        switch tone {
        case .highlight:
            content.foregroundStyle(ink.highlight)
        case .text:
            content.foregroundStyle(ink.text)
        case .dim:
            content.foregroundStyle(ink.dim)
        case .alarm:
            if ink.alarmInverted {
                content
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 2)
                    .background(ink.highlight)
            } else {
                content.foregroundStyle(ink.alarm)
            }
        }
    }
}

extension View {
    func watchTone(_ tone: WatchTone, _ ink: WatchInk) -> some View {
        modifier(WatchToneStyle(tone: tone, ink: ink))
    }

    /// One line of status text: never wraps, shrinks a little before it truncates.
    func watchLine() -> some View {
        lineLimit(1).minimumScaleFactor(0.8)
    }
}

// MARK: - Text helpers

/// `<60` → "12S", `<3600` → "4M", else "2H 5M". Negative values (clock skew) → "0S".
func watchAgeText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0S" }
    let total: Int = Int(min(seconds, 99_999_999))
    if total < 60 { return "\(total)S" }
    if total < 3600 { return "\(total / 60)M" }
    return "\(total / 3600)H \((total % 3600) / 60)M"
}

/// The iPhone's AndroidRemoteStatus.runtimeText rule: "~40M", "~9H 40M", "~99H+".
func watchRuntimeText(minutes: Int) -> String {
    let total: Int = max(0, minutes)
    if total >= 99 * 60 { return "~99H+" }
    if total < 60 { return "~\(total)M" }
    return "~\(total / 60)H \(total % 60)M"
}

/// "4.18V".
func watchVoltsText(mv: Int) -> String {
    String(format: "%.2fV", Double(mv) / 1000.0)
}

/// "UP 14M" / "UP 2H 14M" (the iPhone's esp32DeviceText rule).
func watchUptimeText(seconds: Int) -> String {
    let minutes: Int = max(0, seconds) / 60
    return minutes < 60 ? "UP \(minutes)M" : "UP \(minutes / 60)H \(minutes % 60)M"
}

/// Seconds since a Unix time, by this watch's clock.
func watchSecondsSince(_ unixSeconds: Double, now: Date = Date()) -> Double {
    now.timeIntervalSince1970 - unixSeconds
}
