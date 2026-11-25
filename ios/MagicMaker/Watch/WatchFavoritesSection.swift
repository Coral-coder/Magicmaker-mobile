import SwiftUI

// The Apple Watch favourites in the standard theme (docs/WATCH_APP.md 2.3 and 2.5): the star a
// packet row shows, the FAVORITES FULL alert, and SETTINGS → APPLE WATCH with the watch link line
// and the list (tap sends, hold renames, up / down reorder, the star removes after a confirm).

/// The watch star: filled amber when starred, an outline in textDim otherwise. 36 x 36 tap area.
struct FavoriteStarButton: View {
    let on: Bool
    let action: () -> Void

    init(on: Bool, action: @escaping () -> Void) {
        self.on = on
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? MMTheme.amber : MMTheme.textDim)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        // Inside List rows: only the star is the target, and it wins over the row's tap.
        .buttonStyle(.borderless)
        .accessibilityLabel(on ? "Remove from watch favorites" : "Add to watch favorites")
    }
}

extension View {
    /// "FAVORITES FULL (24)" with OK, shown when a star is refused because the list is full.
    func favoritesFullAlert(_ isPresented: Binding<Bool>) -> some View {
        alert(WatchFavoritesStore.fullTitle, isPresented: isPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(WatchFavoritesStore.fullMessage)
        }
    }
}

// MARK: - SETTINGS → APPLE WATCH

/// The watch link line, then the favourites in the watch's order.
struct SettingsWatchSection: View {
    @ObservedObject private var favorites: WatchFavoritesStore = WatchFavoritesStore.shared
    @ObservedObject private var bridge: WatchBridge = WatchBridge.shared
    @State private var renameRequest: RenameRequest? = nil
    @State private var deleteRequest: DeleteRequest? = nil

    static let emptyText: String = "Star a packet on TX, WAND (colours, codes, quick button) or LAB (MY PRESETS) to add it here. The watch sends through this iPhone and its relay."
    static let hint: String = "TAP SENDS · HOLD RENAMES"

    init() {}

    var body: some View {
        content
            .renamePrompt($renameRequest)
            .confirmDelete($deleteRequest)
    }

    private var content: some View {
        let items: [WatchFavorite] = favorites.items
        return VStack(alignment: .leading, spacing: 2) {
            header(items.count)
            linkLine
            if items.isEmpty {
                Text(SettingsWatchSection.emptyText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(SettingsWatchSection.hint)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, favorite in
                        row(favorite, index: index, count: items.count)
                    }
                }
            }
        }
    }

    private func header(_ count: Int) -> some View {
        HStack(spacing: 6) {
            Text("APPLE WATCH")
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            Spacer(minLength: 4)
            Text("\(count)/\(WatchProtocol.maxFavorites)")
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
        }
    }

    /// Ticks each second so "SYNCED 12S AGO" counts up.
    private var linkLine: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
            Text(bridge.linkText(now: timeline.date))
                .font(MMTheme.techLabel())
                .foregroundStyle(linkColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var linkColor: Color {
        switch bridge.linkState {
        case .notInstalled: return MMTheme.amber
        case .live: return MMTheme.cyan
        default: return MMTheme.textDim
        }
    }

    private func row(_ favorite: WatchFavorite, index: Int, count: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                rowText(favorite)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        WatchBridge.shared.sendFromPhone(favorite)
                    }
                    .onLongPressGesture(minimumDuration: 0.4) {
                        askRename(favorite)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Sends it from this iPhone")
                iconButton("chevron.up", label: "Move up", enabled: index > 0) {
                    favorites.move(id: favorite.id, by: -1)
                }
                iconButton("chevron.down", label: "Move down", enabled: index < count - 1) {
                    favorites.move(id: favorite.id, by: 1)
                }
                iconButton("star.fill", label: "Remove from watch favorites", enabled: true, color: MMTheme.amber) {
                    askRemove(favorite)
                }
            }
            .padding(.vertical, 4)
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
        }
    }

    private func rowText(_ favorite: WatchFavorite) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(favorite.label.uppercased())
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
                    .lineLimit(1)
                if favorite.phoneIsQuick {
                    Text("QUICK")
                        .font(MMTheme.techLabel(8))
                        .foregroundStyle(MMTheme.amber)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(MMTheme.amber, lineWidth: 0.5))
                        .fixedSize()
                }
            }
            HStack(spacing: 4) {
                if let rgb = favorite.phoneSwatchRGB {
                    Circle()
                        .fill(VFDSettings.color(rgb))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(MMTheme.panelLine, lineWidth: 0.5))
                }
                Text(favorite.phoneDetailText)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconButton(_ systemName: String, label: String, enabled: Bool, color: Color = MMTheme.cyan,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? color : MMTheme.panelLine)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func askRename(_ favorite: WatchFavorite) {
        let id: String = favorite.id
        renameRequest = RenameRequest(title: "Rename favorite", initial: favorite.label) { (newLabel: String) in
            WatchFavoritesStore.shared.rename(id: id, label: newLabel)
        }
    }

    private func askRemove(_ favorite: WatchFavorite) {
        let id: String = favorite.id
        deleteRequest = DeleteRequest(
            title: "Remove from watch favorites?",
            label: favorite.label,
            hex: favorite.hex,
            confirmLabel: "REMOVE"
        ) {
            WatchFavoritesStore.shared.remove(id: id)
        }
    }
}
