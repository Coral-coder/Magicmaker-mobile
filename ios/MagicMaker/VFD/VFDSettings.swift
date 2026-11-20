import SwiftUI
import UIKit

// The theme setting both themes share: which look the app shows (the standard SwiftUI screens or
// the VFD dot-matrix display) and the VFD base colour, persisted in UserDefaults side by side.

/// The app's look.
enum VFDTheme: String, CaseIterable, Identifiable {
    case standard
    case vfd

    var id: String { rawValue }

    /// STANDARD / VFD, as both THEME selectors show it.
    var label: String {
        switch self {
        case .standard: return "STANDARD"
        case .vfd: return "VFD"
        }
    }
}

/// Theme and VFD base colour (`VFDSettings.shared`). UserDefaults: `MMUITheme` = "standard" /
/// "vfd" (default standard); `MMVFDBase` = a preset name ("AMBER", the default) or "#RRGGBB";
/// `MMVFDCustomBase` = the last custom colour as "#RRGGBB" (what CUSTOM shows and selects).
final class VFDSettings: ObservableObject {
    static let shared: VFDSettings = VFDSettings()

    static let themeKey: String = "MMUITheme"
    static let baseKey: String = "MMVFDBase"
    static let customKey: String = "MMVFDCustomBase"
    /// CUSTOM before a colour was ever picked.
    static let defaultCustomRGB: VFDRGB = VFDRGB(r: 0xFF, g: 0x88, b: 0x00)
    static let customLabel: String = "CUSTOM"

    @Published var theme: VFDTheme = VFDSettings.loadTheme() {
        didSet {
            if theme != oldValue {
                UserDefaults.standard.set(theme.rawValue, forKey: VFDSettings.themeKey)
            }
        }
    }

    /// The base colour the VFD theme is drawn in. Choosing a custom one also remembers it as
    /// `customRGB`.
    @Published var base: VFDBase = VFDSettings.loadBase() {
        didSet {
            if base != oldValue {
                UserDefaults.standard.set(base.persisted, forKey: VFDSettings.baseKey)
            }
            if case .custom(let rgb) = base, rgb != customRGB {
                customRGB = rgb
            }
        }
    }

    /// The colour CUSTOM stands for, kept while a preset is selected.
    @Published var customRGB: VFDRGB = VFDSettings.loadCustom() {
        didSet {
            if customRGB != oldValue {
                UserDefaults.standard.set(customRGB.hex, forKey: VFDSettings.customKey)
            }
        }
    }

    init() {}

    // MARK: Reading

    var isVFD: Bool { return theme == .vfd }

    /// The 5 ink colours of the current base.
    var palette: [VFDRGB] { return VFDPalette.colors(for: base) }

    /// The BASE COLOUR selector's items: the presets in order, then CUSTOM.
    static var baseItems: [String] {
        var items: [String] = []
        for preset in VFDBase.presets {
            items.append(preset.name)
        }
        items.append(customLabel)
        return items
    }

    /// Index in `baseItems` of the current base: its preset, or CUSTOM (the last item).
    var baseIndex: Int {
        let resolved = base.resolved
        if let name = resolved.name {
            var i: Int = 0
            for preset in VFDBase.presets {
                if preset.name == name { return i }
                i += 1
            }
        }
        return VFDBase.presets.count
    }

    var baseIsCustom: Bool { return baseIndex == VFDBase.presets.count }

    /// RGB of item `index` of `baseItems` (CUSTOM = `customRGB`).
    func itemRGB(_ index: Int) -> VFDRGB {
        if index >= 0 && index < VFDBase.presets.count {
            return VFDBase.presets[index].rgb
        }
        return customRGB
    }

    // MARK: Changing

    /// Select item `index` of `baseItems`: a preset, or CUSTOM with `customRGB`.
    func selectBase(index: Int) {
        if index >= 0 && index < VFDBase.presets.count {
            base = .preset(VFDBase.presets[index].name)
        } else {
            base = .custom(customRGB)
        }
    }

    /// Pick a custom base colour and select it.
    func selectCustom(_ rgb: VFDRGB) {
        customRGB = rgb
        base = .custom(rgb)
    }

    // MARK: SwiftUI colours

    static func color(_ rgb: VFDRGB) -> Color {
        return Color(red: Double(rgb.r) / 255.0, green: Double(rgb.g) / 255.0, blue: Double(rgb.b) / 255.0)
    }

    /// The colour's sRGB channels, clamped to 0...255.
    static func rgb(_ color: Color) -> VFDRGB {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if !UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
            return VFDBase.amberRGB
        }
        return VFDRGB(unitRed: Double(r), green: Double(g), blue: Double(b))
    }

    // MARK: Persistence

    private static func loadTheme() -> VFDTheme {
        let raw: String = UserDefaults.standard.string(forKey: themeKey) ?? ""
        return VFDTheme(rawValue: raw.lowercased()) ?? .standard
    }

    private static func loadBase() -> VFDBase {
        guard let raw = UserDefaults.standard.string(forKey: baseKey) else { return VFDBase.amber }
        return VFDBase(persisted: raw)
    }

    private static func loadCustom() -> VFDRGB {
        if let raw = UserDefaults.standard.string(forKey: customKey), let rgb = VFDRGB.parse(raw) {
            return rgb
        }
        if case .custom(let rgb) = loadBase() {
            return rgb
        }
        return defaultCustomRGB
    }
}

/// The system colour picker for the CUSTOM base colour: a picked colour is stored and selected.
/// The standard SETTINGS screen shows it inline; the VFD one opens `VFDCustomColorSheet`.
struct VFDBaseColorPicker: View {
    @ObservedObject private var settings: VFDSettings = VFDSettings.shared
    private let title: String

    init(title: String = "CUSTOM COLOUR") {
        self.title = title
    }

    var body: some View {
        ColorPicker(selection: colorBinding, supportsOpacity: false) {
            Text(title)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { VFDSettings.color(settings.customRGB) },
            set: { picked in settings.selectCustom(VFDSettings.rgb(picked)) }
        )
    }
}

/// The CUSTOM base colour sheet the VFD SETTINGS screen opens.
struct VFDCustomColorSheet: View {
    @ObservedObject private var settings: VFDSettings = VFDSettings.shared

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BASE COLOUR · CUSTOM")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(VFDSettings.color(settings.customRGB))
                    .frame(width: 44, height: 44)
                Text(settings.customRGB.hex)
                    .font(MMTheme.techHeader(14))
                    .foregroundStyle(MMTheme.textPrimary)
                Spacer(minLength: 0)
            }
            VFDBaseColorPicker(title: "PICK A COLOUR")
            Text("The VFD theme lights its text, borders and controls in shades of this colour.")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
