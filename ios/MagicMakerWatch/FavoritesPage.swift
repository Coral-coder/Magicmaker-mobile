import SwiftUI

/// FAVORITES (docs/WATCH_APP.md 5.3): the packets starred on the iPhone, in the iPhone's order.
/// A tap sends one through the iPhone and its relay, exactly as a tap on the iPhone row would.
struct FavoritesPage: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.isLuminanceReduced) private var reduced: Bool

    var body: some View {
        let ink: WatchInk = WatchInk(model.theme, reduced: reduced)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("FAVORITES")
                    .font(WatchFont.smallBold)
                    .watchTone(.highlight, ink)
                    .watchLine()
                let link: (text: String, tone: WatchTone) = linkLine
                Text(link.text)
                    .font(WatchFont.small)
                    .watchTone(link.tone, ink)
                    .lineLimit(2)
                if model.favorites.isEmpty {
                    emptyNote(ink)
                } else {
                    ForEach(model.favorites) { (favorite: WatchFavorite) in
                        FavoriteCard(favorite: favorite,
                                     state: model.rows[favorite.id] ?? .idle,
                                     ink: ink,
                                     reachable: model.reachable,
                                     reduced: reduced) {
                            model.send(favorite)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// The link line under the title: which relay a tap goes through, or why it cannot.
    private var linkLine: (text: String, tone: WatchTone) {
        if !model.companionInstalled { return ("INSTALL MAGICMAKER ON IPHONE", .alarm) }
        if !model.reachable { return ("IPHONE NOT REACHABLE", .alarm) }
        guard let status: WatchStatus = model.status else { return ("WAITING FOR IPHONE…", .dim) }
        if status.linked { return ("VIA " + status.selected + " · LINKED", .dim) }
        let state: String = status.selected == WatchProtocol.viaEsp32 ? status.esp32.state : status.android.state
        if state == "LINKING" { return (status.selected + " LINKING…", .dim) }
        return (status.selected + " NOT LINKED", .alarm)
    }

    private func emptyNote(_ ink: WatchInk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NO FAVORITES")
                .font(WatchFont.title)
                .watchTone(.text, ink)
            Text("STAR ★ PACKETS IN THE IPHONE APP: TX, WAND, LAB")
                .font(WatchFont.small)
                .watchTone(.dim, ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}

/// One favourite: a full-width card, inverted while it is being sent.
struct FavoriteCard: View {
    let favorite: WatchFavorite
    let state: WatchRowState
    let ink: WatchInk
    let reachable: Bool
    let reduced: Bool
    let action: () -> Void

    var body: some View {
        let sending: Bool = state == .sending
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(favorite.label.uppercased())
                    .font(WatchFont.title)
                    .foregroundStyle(sending ? Color.black : ink.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !reduced {
                    detailLine(sending: sending)
                }
                stateLine
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(sending ? ink.highlight : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(ink.dim, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        // Dimmed while the iPhone is away, but still tappable: a tap then says why nothing happens.
        .opacity(reachable ? 1.0 : 0.6)
        .accessibilityHint("Sends it through the iPhone")
    }

    /// "● WAND · …6F1D · 0.5S": the swatch (wands), kind, last hex digits and time on air.
    private func detailLine(sending: Bool) -> some View {
        HStack(spacing: 4) {
            if favorite.kind == WatchFavorite.Kind.wand, let swatch: String = favorite.swatch {
                Circle()
                    .fill(Color(watchHex: swatch))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(sending ? Color.black : Color.clear, lineWidth: 1))
            }
            Text(detailText)
                .font(WatchFont.small)
                .foregroundStyle(sending ? Color.black : ink.dim)
                .watchLine()
        }
    }

    private var detailText: String {
        var text: String = kindTag + " · …" + String(favorite.hex.uppercased().suffix(4))
        if let ms: Int = favorite.onAirMs, ms > 0 {
            text += " · " + FavoriteCard.secondsText(ms: ms)
        }
        return text
    }

    private var kindTag: String {
        if favorite.source == WatchFavorite.Source.wandQuick { return "QUICK" }
        switch favorite.burst {
        case WatchFavorite.Burst.starlight: return "WAND"
        case WatchFavorite.Burst.ping: return "PING"
        case WatchFavorite.Burst.command: return "BAND"
        default: return favorite.kind.uppercased()
        }
    }

    /// "4S" for whole seconds, otherwise one decimal ("0.5S").
    private static func secondsText(ms: Int) -> String {
        if ms % 1000 == 0 { return "\(ms / 1000)S" }
        return String(format: "%.1fS", Double(ms) / 1000.0)
    }

    @ViewBuilder
    private var stateLine: some View {
        switch state {
        case .idle:
            EmptyView()
        case .sending:
            Text("SENDING…")
                .font(WatchFont.smallBold)
                .foregroundStyle(Color.black)
                .watchLine()
        case .result(let ok, let text, _):
            Text(text)
                .font(WatchFont.smallBold)
                .watchTone(ok ? .highlight : .alarm, ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
