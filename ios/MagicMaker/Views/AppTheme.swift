import SwiftUI

enum MMTheme {
    static let navy = Color(red: 6 / 255, green: 13 / 255, blue: 24 / 255)
    static let panel = Color(red: 12 / 255, green: 30 / 255, blue: 54 / 255)
    static let panelLine = Color(red: 30 / 255, green: 58 / 255, blue: 95 / 255)
    static let cyan = Color(red: 92 / 255, green: 225 / 255, blue: 230 / 255)
    static let cyanDim = Color(red: 42 / 255, green: 143 / 255, blue: 160 / 255)
    static let amber = Color(red: 255 / 255, green: 184 / 255, blue: 28 / 255)
    static let textPrimary = Color(red: 232 / 255, green: 244 / 255, blue: 255 / 255)
    static let textDim = Color(red: 127 / 255, green: 163 / 255, blue: 196 / 255)
    static let error = Color(red: 255 / 255, green: 107 / 255, blue: 107 / 255)

    static func techLabel(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    static func techHeader(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

struct MMCompactButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(title.uppercased(), action: action)
            .font(MMTheme.techLabel())
            .buttonStyle(.bordered)
            .tint(MMTheme.cyan)
            .disabled(!enabled)
    }
}

struct MMPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(title.uppercased(), action: action)
            .font(MMTheme.techLabel())
            .buttonStyle(.borderedProminent)
            .tint(MMTheme.cyan)
            .disabled(!enabled)
    }
}

struct RemotePacketRow: View {
    let label: String
    let hex: String
    var subtitle: String = ""
    var highlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(MMTheme.techLabel())
                    .foregroundStyle(highlighted ? MMTheme.cyan : MMTheme.textPrimary)
                Text(hex)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle.uppercased())
                        .font(MMTheme.techLabel(9))
                        .foregroundStyle(MMTheme.textDim)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(highlighted ? MMTheme.cyan.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        Rectangle()
            .fill(MMTheme.panelLine)
            .frame(height: 0.5)
    }
}

struct SwipeRemotePacketRow: View {
    let label: String
    let hex: String
    var subtitle: String = ""
    let onTap: () -> Void
    var onPromote: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var disabled: Bool = false

    var body: some View {
        RemotePacketRow(
            label: label,
            hex: hex,
            subtitle: subtitle,
            action: onTap
        )
        .disabled(disabled)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let onPromote {
                Button(action: onPromote) {
                    Label("TX/TAG", systemImage: "plus.circle")
                }
                .tint(MMTheme.cyan)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

struct CollapsibleSectionHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MMTheme.textDim)
                Text(title.uppercased())
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                Spacer()
                Text(String(format: "%03d", count))
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct TelemetryBar: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(vm.telemetryLine)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(2)
            if !vm.remoteLinkReady {
                Text(vm.remoteLinkHint)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.amber)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(MMTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MMTheme.panelLine).frame(height: 0.5)
        }
    }
}

struct MMCompactTabBar<Tab: Hashable & Identifiable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String
    let icon: (Tab) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: icon(tab))
                            .font(.system(size: 13, weight: .medium))
                        Text(title(tab))
                            .font(MMTheme.techLabel(8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 5)
                    .padding(.bottom, 3)
                    .foregroundStyle(selection == tab ? MMTheme.cyan : MMTheme.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(tab))
            }
        }
        .background(MMTheme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(MMTheme.panelLine).frame(height: 0.5)
        }
    }
}
