import SwiftUI

// Shared building blocks for the screens: packet rows and lists, the long-press sheet, the
// delete / recategorize / rename dialogs, the settings slider, the section filter, the scrolling
// tab bar and a few small text helpers. Colours and fonts come from `MMTheme`.

// MARK: - Packet row

/// One packet line (the content of Android `SwipePacketRow`): label, hex and an optional subtitle,
/// with an optional colour dot in front and an optional tag (such as "BAND") after the label.
/// The whole width is tappable; a long press calls `onLongPress` when one is given.
///
///     PacketRow(
///         label: pkt.label,
///         hex: pkt.hex,
///         subtitle: "RSSI \(pkt.rssi)",
///         tag: pkt.isBand ? "BAND" : nil,
///         selected: pkt.hex == selectedHex,
///         onTap: { tx.transmit(hex: pkt.hex, label: pkt.label) },
///         onLongPress: { sheetInfo = PacketSheetInfo(title: pkt.label, hex: pkt.hex, actions: actions) }
///     )
///     .packetSwipeActions(onDelete: { deleteRequest = request(for: pkt) })
///     .mmListRow()
struct PacketRow: View {
    let label: String
    let hex: String
    let subtitle: String
    let accent: Color?
    let tag: String?
    let selected: Bool
    let onTap: () -> Void
    let onLongPress: (() -> Void)?

    @State private var flash: Bool = false

    init(
        label: String,
        hex: String,
        subtitle: String = "",
        accent: Color? = nil,
        tag: String? = nil,
        selected: Bool = false,
        onTap: @escaping () -> Void,
        onLongPress: (() -> Void)? = nil
    ) {
        self.label = label
        self.hex = hex
        self.subtitle = subtitle
        self.accent = accent
        self.tag = tag
        self.selected = selected
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    var body: some View {
        if let onLongPress {
            tappableRow
                .onLongPressGesture(minimumDuration: 0.4) {
                    onLongPress()
                }
        } else {
            tappableRow
        }
    }

    // The tap gesture is attached before the long press: in that order the List around the row
    // keeps scrolling and swiping.
    private var tappableRow: some View {
        rowBody
            .onTapGesture {
                handleTap()
            }
    }

    private var rowBody: some View {
        HStack(alignment: .center, spacing: 6) {
            if let accent {
                Circle()
                    .fill(accent)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(MMTheme.panelLine, lineWidth: 0.5))
            }
            textLines
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var textLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleLine
            if !hex.isEmpty {
                Text(hex)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
                    .lineLimit(1)
            }
            if !subtitle.isEmpty {
                Text(subtitle.uppercased())
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                    .lineLimit(1)
            }
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(MMTheme.techLabel())
                .foregroundStyle(selected ? MMTheme.cyan : MMTheme.textPrimary)
                .lineLimit(1)
            if let tag, !tag.isEmpty {
                Text(tag.uppercased())
                    .font(MMTheme.techLabel(8))
                    .foregroundStyle(MMTheme.amber)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(MMTheme.amber, lineWidth: 0.5))
                    .fixedSize()
            }
        }
    }

    private var rowBackground: Color {
        if selected || flash {
            return MMTheme.cyan.opacity(0.12)
        }
        return Color.clear
    }

    /// A short highlight stands in for the press feedback a plain gesture does not give.
    private func handleTap() {
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            flash = false
        }
        onTap()
    }
}

// MARK: - Packet lists

extension View {
    /// Row look for a packet line inside a `List`: navy background, tight insets, no system
    /// separator (`PacketRow` draws its own hairline). Put it last on the row, after any
    /// `.packetSwipeActions`. The row must be a direct child of the `List` / `Section` /
    /// `ForEach`, or swipes do nothing.
    ///
    ///     List {
    ///         ForEach(packets) { pkt in
    ///             PacketRow(label: pkt.label, hex: pkt.hex, onTap: { send(pkt) })
    ///                 .mmListRow()
    ///         }
    ///     }
    ///     .mmListStyle()
    func mmListRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
            .listRowBackground(MMTheme.navy)
            .listRowSeparator(.hidden)
    }

    /// List look for this app: plain style, navy background instead of the system one, and no
    /// minimum row height so compact rows stay compact. Apply it to the `List` itself.
    ///
    ///     List { rows }
    ///         .mmListStyle()
    func mmListStyle() -> some View {
        let minRowHeight: CGFloat = 1
        let minHeaderHeight: CGFloat? = 1
        return self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(MMTheme.navy)
            .environment(\.defaultMinListRowHeight, minRowHeight)
            .environment(\.defaultMinListHeaderHeight, minHeaderHeight)
    }

    /// The swipes of Android `SwipePacketRow`: swipe left for DELETE, swipe right for TX / TAG.
    /// A nil handler leaves that side without a swipe. Neither button removes the row by itself,
    /// so `onDelete` may open a confirmation first; the row goes when the data changes.
    ///
    ///     PacketRow(label: pkt.label, hex: pkt.hex, onTap: { send(pkt) })
    ///         .packetSwipeActions(
    ///             onDelete: { deleteRequest = DeleteRequest(title: "Remove from scan list?", label: pkt.label, hex: pkt.hex) { remove(pkt) } },
    ///             onPromote: { promote(pkt) }
    ///         )
    ///         .mmListRow()
    func packetSwipeActions(onDelete: (() -> Void)? = nil, onPromote: (() -> Void)? = nil) -> some View {
        self
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if let onDelete {
                    Button(action: onDelete) {
                        Label("DELETE", systemImage: "trash")
                    }
                    .tint(MMTheme.error)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let onPromote {
                    Button(action: onPromote) {
                        Label("TX / TAG", systemImage: "plus")
                    }
                    .tint(MMTheme.cyanDim)
                }
            }
    }
}

/// Collapsible header for a `List` section: chevron, cyan title and a three-digit count, tappable
/// across the whole width. It paints its own navy background so rows scrolling under a pinned
/// header stay hidden.
///
///     Section {
///         if !collapsed.contains(section) {
///             ForEach(rows) { pkt in
///                 PacketRow(label: pkt.label, hex: pkt.hex, onTap: { send(pkt) })
///                     .mmListRow()
///             }
///         }
///     } header: {
///         MMListSectionHeader(title: section.title, count: rows.count, collapsed: collapsed.contains(section)) {
///             toggle(section)
///         }
///     }
struct MMListSectionHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let action: () -> Void

    init(title: String, count: Int, collapsed: Bool, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.collapsed = collapsed
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            headerLine
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    private var headerLine: some View {
        HStack(spacing: 4) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MMTheme.textDim)
                .frame(width: 12)
            Text(title.uppercased())
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(String(format: "%03d", count))
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MMTheme.navy)
        .contentShape(Rectangle())
    }
}

// MARK: - Long-press sheet

/// One button in a `packetActionSheet` (Android `PacketAction`).
///
///     PacketAction(title: "Transmit") { tx.transmit(hex: pkt.hex, label: pkt.label) }
///     PacketAction(title: "Remove", destructive: true) { deleteRequest = request(for: pkt) }
struct PacketAction: Identifiable {
    let id = UUID()
    let title: String
    let destructive: Bool
    let action: () -> Void

    init(title: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.destructive = destructive
        self.action = action
    }
}

/// What a `packetActionSheet` shows: the packet's label and hex, the colours text (the sheet adds
/// the "COLORS: " prefix; leave it empty for none), a subtitle and the buttons. Build it in the
/// long-press handler and keep it in `@State`. Its `id` is the hex and title, so the same packet
/// is the same sheet.
///
///     sheetInfo = PacketSheetInfo(
///         title: pkt.label,
///         hex: pkt.hex,
///         colorsLine: MagicClassifier.classify(pkt.hex)?.colors ?? "",
///         subtitle: "\(pkt.category.rawValue) · RSSI \(pkt.rssi)",
///         actions: [
///             PacketAction(title: "Transmit") { tx.transmit(hex: pkt.hex, label: pkt.label) },
///             PacketAction(title: "Load in Lab") { vm.loadInLab(hex: pkt.hex, label: pkt.label) },
///             PacketAction(title: "Remove", destructive: true) { deleteRequest = request(for: pkt) },
///         ]
///     )
struct PacketSheetInfo: Identifiable {
    let id: String
    let title: String
    let hex: String
    let colorsLine: String
    let subtitle: String
    let actions: [PacketAction]

    init(
        title: String,
        hex: String,
        colorsLine: String = "",
        subtitle: String = "",
        actions: [PacketAction]
    ) {
        self.id = hex + "|" + title
        self.title = title
        self.hex = hex
        self.colorsLine = colorsLine
        self.subtitle = subtitle
        self.actions = actions
    }
}

extension View {
    /// The long-press menu for a packet (Android `PacketActionSheet`). Attach it once to the
    /// screen's root view and set the binding to show it. A tapped action closes the sheet and
    /// runs once the sheet is gone, so it may open an alert or switch tabs; the binding is nil
    /// again by then.
    ///
    ///     @State private var sheetInfo: PacketSheetInfo?
    ///
    ///     content
    ///         .packetActionSheet($sheetInfo)
    func packetActionSheet(_ info: Binding<PacketSheetInfo?>) -> some View {
        modifier(MMPacketActionSheetModifier(info: info))
    }
}

private struct MMPacketActionSheetModifier: ViewModifier {
    @Binding var info: PacketSheetInfo?
    /// The tapped action, held until the sheet has gone.
    @State private var pending: PacketAction? = nil

    init(info: Binding<PacketSheetInfo?>) {
        self._info = info
    }

    func body(content: Content) -> some View {
        content.sheet(item: $info, onDismiss: { runPending() }) { shown in
            MMPacketActionSheetView(info: shown, onPick: { action in pick(action) })
        }
    }

    private func pick(_ action: PacketAction) {
        pending = action
        info = nil
        // The sheet reports its dismissal; this only covers a dismissal that is never reported.
        let pickedId: UUID = action.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if pending?.id == pickedId {
                runPending()
            }
        }
    }

    private func runPending() {
        guard let action = pending else { return }
        pending = nil
        action.action()
    }
}

private struct MMPacketActionSheetView: View {
    let info: PacketSheetInfo
    let onPick: (PacketAction) -> Void

    init(info: PacketSheetInfo, onPick: @escaping (PacketAction) -> Void) {
        self.info = info
        self.onPick = onPick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
                .padding(.vertical, 6)
            ScrollView {
                actionList
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MMTheme.panel)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(MMTheme.panel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.title.uppercased())
                .font(MMTheme.techHeader(12))
                .foregroundStyle(MMTheme.cyan)
                .lineLimit(2)
            Text(info.hex)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.cyanDim)
                .lineLimit(2)
            if !colorsText.isEmpty {
                Text(colorsText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.cyan)
                    .lineLimit(1)
            }
            if !subtitleText.isEmpty {
                Text(subtitleText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .lineLimit(1)
            }
        }
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // By position: the list is fixed while the sheet is up, whatever the action ids are.
            ForEach(info.actions.indices, id: \.self) { index in
                actionButton(info.actions[index])
            }
        }
    }

    private func actionButton(_ action: PacketAction) -> some View {
        Button {
            onPick(action)
        } label: {
            Text(action.title.uppercased())
                .font(MMTheme.techLabel(12))
                .foregroundStyle(action.destructive ? MMTheme.error : MMTheme.cyan)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var colorsText: String {
        let trimmed: String = info.colorsLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let upper: String = trimmed.uppercased()
        if upper.hasPrefix("COLORS:") { return upper }
        return "COLORS: " + upper
    }

    private var subtitleText: String {
        let trimmed: String = info.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.uppercased()
    }
}

// MARK: - Confirm delete

/// A pending delete for `confirmDelete` (Android `ConfirmDeleteDialog`). `confirm` runs only when
/// the user taps the destructive button. `hex` may be left out for a delete that is not one packet.
///
///     deleteRequest = DeleteRequest(title: "Delete from TX library?", label: packet.label, hex: packet.hex) {
///         store.deletePacketById(packet.id)
///     }
struct DeleteRequest: Identifiable {
    let id = UUID()
    let title: String
    let label: String
    let hex: String
    let confirmLabel: String
    let confirm: () -> Void

    init(
        title: String,
        label: String,
        hex: String = "",
        confirmLabel: String = "DELETE",
        confirm: @escaping () -> Void
    ) {
        self.title = title
        self.label = label
        self.hex = hex
        self.confirmLabel = confirmLabel
        self.confirm = confirm
    }
}

extension View {
    /// Asks before deleting: the request's title, then its label and hex, a destructive button
    /// and CANCEL. Attach it once to the screen's root view; the binding is cleared when the
    /// alert closes.
    ///
    ///     @State private var deleteRequest: DeleteRequest?
    ///
    ///     content
    ///         .confirmDelete($deleteRequest)
    func confirmDelete(_ request: Binding<DeleteRequest?>) -> some View {
        modifier(MMConfirmDeleteModifier(request: request))
    }
}

private struct MMConfirmDeleteModifier: ViewModifier {
    @Binding var request: DeleteRequest?

    init(request: Binding<DeleteRequest?>) {
        self._request = request
    }

    func body(content: Content) -> some View {
        content.alert(
            request?.title ?? "",
            isPresented: presented,
            presenting: request
        ) { req in
            Button(req.confirmLabel, role: .destructive) {
                req.confirm()
            }
            Button("CANCEL", role: .cancel) { }
        } message: { req in
            Text(MMConfirmDeleteModifier.message(for: req))
        }
    }

    private var presented: Binding<Bool> {
        Binding(
            get: { request != nil },
            set: { shown in
                if !shown { request = nil }
            }
        )
    }

    private static func message(for req: DeleteRequest) -> String {
        let label: String = req.label.uppercased()
        if req.hex.isEmpty { return label }
        if label.isEmpty { return req.hex }
        return label + "\n" + req.hex
    }
}

// MARK: - Category picker

/// A pending recategorize for `categoryPicker` (Android `CategoryPickerDialog`): `title` heads the
/// dialog, `label` (normally the packet's label) is shown under it, `current` is marked with a
/// tick, and `pick` receives the category the user chose.
///
///     categoryRequest = CategoryPickRequest(label: packet.label, current: packet.category) { category in
///         store.recategorizePacket(id: packet.id, category: category)
///     }
struct CategoryPickRequest: Identifiable {
    let id = UUID()
    let title: String
    let label: String
    let current: MagicCategory?
    let pick: (MagicCategory) -> Void

    init(
        title: String = "Recategorize",
        label: String = "",
        current: MagicCategory? = nil,
        pick: @escaping (MagicCategory) -> Void
    ) {
        self.title = title
        self.label = label
        self.current = current
        self.pick = pick
    }
}

extension View {
    /// Lets the user pick one of SHOW / ANIMATION / COLOR / UNKNOWN. Attach it once to the screen's
    /// root view; the binding is cleared when the dialog closes.
    ///
    ///     @State private var categoryRequest: CategoryPickRequest?
    ///
    ///     content
    ///         .categoryPicker($categoryRequest)
    func categoryPicker(_ request: Binding<CategoryPickRequest?>) -> some View {
        modifier(MMCategoryPickerModifier(request: request))
    }
}

private struct MMCategoryPickerModifier: ViewModifier {
    @Binding var request: CategoryPickRequest?

    init(request: Binding<CategoryPickRequest?>) {
        self._request = request
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            request?.title ?? "",
            isPresented: presented,
            titleVisibility: .visible,
            presenting: request
        ) { req in
            ForEach(MagicCategory.allCases, id: \.self) { category in
                Button(MMCategoryPickerModifier.buttonTitle(category, current: req.current)) {
                    req.pick(category)
                }
            }
            Button("CANCEL", role: .cancel) { }
        } message: { req in
            if !req.label.isEmpty {
                Text(req.label)
            }
        }
    }

    private var presented: Binding<Bool> {
        Binding(
            get: { request != nil },
            set: { shown in
                if !shown { request = nil }
            }
        )
    }

    private static func buttonTitle(_ category: MagicCategory, current: MagicCategory?) -> String {
        if category == current {
            return category.rawValue + " ✓"
        }
        return category.rawValue
    }
}

// MARK: - Rename prompt

/// A pending rename for `renamePrompt` (Android `RenameDialog`). The field starts with `initial`;
/// `save` receives the text as typed, and is not called for a blank one.
///
///     renameRequest = RenameRequest(initial: packet.label) { newLabel in
///         store.renamePacket(id: packet.id, newLabel: newLabel)
///     }
struct RenameRequest: Identifiable {
    let id = UUID()
    let title: String
    let initial: String
    let save: (String) -> Void

    init(title: String = "Rename packet", initial: String, save: @escaping (String) -> Void) {
        self.title = title
        self.initial = initial
        self.save = save
    }
}

extension View {
    /// An alert with one text field, SAVE and CANCEL. Attach it once to the screen's root view;
    /// the binding is cleared when the alert closes.
    ///
    ///     @State private var renameRequest: RenameRequest?
    ///
    ///     content
    ///         .renamePrompt($renameRequest)
    func renamePrompt(_ request: Binding<RenameRequest?>) -> some View {
        modifier(MMRenamePromptModifier(request: request))
    }
}

private struct MMRenamePromptModifier: ViewModifier {
    @Binding var request: RenameRequest?
    /// What the user has typed, and for which prompt. A prompt nobody has typed into yet shows
    /// its own `initial`, so the field is filled the moment the alert opens. The key is the
    /// prompt's content, not its id, so a request rebuilt while the alert is up keeps the typing.
    @State private var draft: String = ""
    @State private var draftKey: String? = nil

    init(request: Binding<RenameRequest?>) {
        self._request = request
    }

    func body(content: Content) -> some View {
        content.alert(
            request?.title ?? "",
            isPresented: presented,
            presenting: request
        ) { req in
            TextField("LABEL", text: textBinding(for: req))
                .autocorrectionDisabled()
            Button("SAVE") {
                commit(req)
            }
            Button("CANCEL", role: .cancel) {
                draftKey = nil
            }
        }
    }

    private var presented: Binding<Bool> {
        Binding(
            get: { request != nil },
            set: { shown in
                if !shown { request = nil }
            }
        )
    }

    private static func key(for req: RenameRequest) -> String {
        req.title + "|" + req.initial
    }

    private func text(for req: RenameRequest) -> String {
        if draftKey == MMRenamePromptModifier.key(for: req) {
            return draft
        }
        return req.initial
    }

    private func textBinding(for req: RenameRequest) -> Binding<String> {
        Binding(
            get: { text(for: req) },
            set: { newValue in
                draft = newValue
                draftKey = MMRenamePromptModifier.key(for: req)
            }
        )
    }

    private func commit(_ req: RenameRequest) {
        let entered: String = text(for: req)
        draftKey = nil
        let trimmed: String = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        req.save(entered)
    }
}

// MARK: - Setting slider

/// Port of Android `SettingSlider`: a title with the live value, then – / + step buttons around a
/// slider. While the thumb is dragged only the value text follows it; `value` is written and
/// `onCommit` is called when the drag ends or a step button is tapped, always with a value snapped
/// to `step` and clamped to `range`. The value text is the number (whole when `step` is whole)
/// followed by `unit`; use `.valueText { ... }` for any other wording.
///
///     SettingSlider(
///         title: "COMMAND BURST",
///         value: $burstMs,
///         range: Double(TransmitTiming.minCommandBurstMs)...Double(TransmitTiming.maxCommandBurstMs),
///         step: 50,
///         unit: "ms",
///         hint: "Total wake+command interleave window",
///         onCommit: { ms in store.saveCommandBurstMs(Int(ms)) }
///     )
struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let hint: String
    let onCommit: (Double) -> Void
    private var formatter: ((Double) -> String)? = nil

    @State private var draft: Double = 0
    @State private var dragging: Bool = false
    /// Bumped on every commit, so the slider re-reads `value` even when its source does not publish.
    @State private var commitTick: Int = 0

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String = "",
        hint: String = "",
        onCommit: @escaping (Double) -> Void = { _ in }
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.hint = hint
        self.onCommit = onCommit
    }

    /// Replaces the default value text.
    ///
    ///     SettingSlider(title: "INTERVAL", value: $intervalSec, range: 0.5...30, step: 0.5)
    ///         .valueText { sec in String(format: "%.1fS", sec) }
    func valueText(_ format: @escaping (Double) -> String) -> SettingSlider {
        var copy = self
        copy.formatter = format
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerRow
            controlRow
            if !hint.isEmpty {
                Text(hint)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(displayText)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.cyan)
                .lineLimit(1)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 6) {
            stepButton("–", label: "Decrease", enabled: value > range.lowerBound) {
                commit(snap(value - step))
            }
            if range.upperBound > range.lowerBound {
                Slider(value: sliderValue, in: range) { editing in
                    editingChanged(editing)
                }
                .tint(MMTheme.cyan)
                .accessibilityLabel(title)
            } else {
                Spacer(minLength: 0)
            }
            stepButton("+", label: "Increase", enabled: value < range.upperBound) {
                commit(snap(value + step))
            }
        }
    }

    private func stepButton(
        _ symbol: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(MMTheme.techHeader(14))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .tint(MMTheme.cyan)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// The thumb follows the drag; otherwise it shows the committed value.
    private var sliderValue: Binding<Double> {
        Binding(
            get: { dragging ? draft : clamp(value) },
            set: { newValue in
                sliderMoved(newValue)
            }
        )
    }

    private func sliderMoved(_ newValue: Double) {
        draft = newValue
        // A change with no drag in progress (an accessibility adjustment) is complete as it is.
        if !dragging {
            commit(snap(newValue))
        }
    }

    private func editingChanged(_ editing: Bool) {
        if editing {
            draft = clamp(value)
            dragging = true
        } else if dragging {
            dragging = false
            commit(snap(draft))
        }
    }

    private func commit(_ newValue: Double) {
        value = newValue
        commitTick += 1
        onCommit(newValue)
    }

    private func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return range.lowerBound }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// Nearest multiple of `step`, halves rounding up, kept inside the range.
    private func snap(_ v: Double) -> Double {
        guard v.isFinite else { return range.lowerBound }
        guard step > 0 else { return clamp(v) }
        let steps: Double = (v / step + 0.5).rounded(.down)
        return clamp(steps * step)
    }

    private var displayText: String {
        _ = commitTick
        let shown: Double = snap(dragging ? draft : value)
        if let formatter {
            return formatter(shown)
        }
        return SettingSlider.numberText(shown, step: step) + unit
    }

    private static func numberText(_ v: Double, step: Double) -> String {
        guard v.isFinite else { return "0" }
        let places: Int = decimalPlaces(for: step)
        if places == 0 {
            let whole: Double = v.rounded()
            if abs(whole) < 1e15 {
                return String(Int(whole))
            }
            return String(whole)
        }
        if places == 1 {
            return String(format: "%.1f", v)
        }
        return String(format: "%.2f", v)
    }

    private static func decimalPlaces(for step: Double) -> Int {
        if step <= 0 { return 1 }
        if step == step.rounded() { return 0 }
        let tenths: Double = step * 10
        if tenths == tenths.rounded() { return 1 }
        return 2
    }
}

// MARK: - Section filter

/// Port of Android `SectionFilterDropdown`: a "CLASS n/8" button whose menu ticks the sections that
/// are shown. Tapping a section adds it to or removes it from `visible`; the menu stays open.
///
///     @State private var visibleSections: Set<LivePacketSection> = Set(LivePacketSection.allCases)
///
///     SectionFilterMenu(visible: $visibleSections)
struct SectionFilterMenu: View {
    @Binding var visible: Set<LivePacketSection>

    init(visible: Binding<Set<LivePacketSection>>) {
        self._visible = visible
    }

    var body: some View {
        Menu {
            ForEach(LivePacketSection.allCases) { section in
                Button {
                    toggle(section)
                } label: {
                    if visible.contains(section) {
                        Label(section.title, systemImage: "checkmark")
                    } else {
                        Text(section.title)
                    }
                }
            }
        } label: {
            menuLabel
        }
        .menuActionDismissBehavior(.disabled)
    }

    private var menuLabel: some View {
        HStack(spacing: 3) {
            Text("CLASS \(visible.count)/\(LivePacketSection.allCases.count)")
                .font(MMTheme.techLabel())
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(MMTheme.cyan)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(MMTheme.cyanDim, lineWidth: 0.5))
        .contentShape(Rectangle())
    }

    private func toggle(_ section: LivePacketSection) {
        if visible.contains(section) {
            visible.remove(section)
        } else {
            visible.insert(section)
        }
    }
}

// MARK: - Scrolling tab bar

private let mmScrollTabMinWidth: CGFloat = 58

/// A tab bar for more tabs than fit across a phone: icon + label buttons in a horizontal scroller
/// that keeps the selected tab in view. On a wide screen the tabs share the width evenly. Same
/// colours as `MMCompactTabBar`.
///
///     .safeAreaInset(edge: .bottom, spacing: 0) {
///         MMScrollTabBar(selection: $tab, tabs: MainTab.allCases, title: { $0.title }, icon: { $0.icon })
///     }
struct MMScrollTabBar<Tab: Hashable & Identifiable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String
    let icon: (Tab) -> String

    init(
        selection: Binding<Tab>,
        tabs: [Tab],
        title: @escaping (Tab) -> String,
        icon: @escaping (Tab) -> String
    ) {
        self._selection = selection
        self.tabs = tabs
        self.title = title
        self.icon = icon
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                tabStrip
            }
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
            .onChange(of: selection) { _, newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .background(MMTheme.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabCell(tab)
            }
        }
    }

    private func tabCell(_ tab: Tab) -> some View {
        tabButton(tab)
            .containerRelativeFrame(.horizontal) { length, _ in
                tabWidth(length)
            }
            .id(tab)
    }

    private func tabButton(_ tab: Tab) -> some View {
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
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(selection == tab ? MMTheme.cyan : Color.clear)
                    .frame(height: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(tab))
    }

    /// An even share of the bar, but never narrower than a readable tab.
    private func tabWidth(_ barWidth: CGFloat) -> CGFloat {
        let count: CGFloat = CGFloat(max(tabs.count, 1))
        let even: CGFloat = barWidth / count
        return max(mmScrollTabMinWidth, even)
    }
}

// MARK: - Small pieces

/// One line of status text: dim (or the given colour), uppercase, tech font, full width.
///
///     StatusLine(tx.status)
///     StatusLine(text: "NO RELAY LINKED", color: MMTheme.amber)
struct StatusLine: View {
    let text: String
    let color: Color

    init(text: String, color: Color = MMTheme.textDim) {
        self.text = text
        self.color = color
    }

    init(_ text: String, color: Color = MMTheme.textDim) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(MMTheme.techLabel(9))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The cyan tech header that titles a block of controls.
///
///     MMSectionTitle("LIVE RX")
struct MMSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    init(title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(MMTheme.techHeader())
            .foregroundStyle(MMTheme.cyan)
            .lineLimit(1)
    }
}

/// A padded panel with the hairline border used across the app; the content is stacked
/// vertically, leading-aligned.
///
///     MMPanel {
///         MMSectionTitle("TRANSMISSION")
///         StatusLine(tx.status)
///     }
struct MMPanel<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(MMTheme.panel)
        .overlay(Rectangle().stroke(MMTheme.panelLine, lineWidth: 0.5))
    }
}

// MARK: - Text helpers

/// The short form of a source id for display: its last 8 characters, uppercased. Empty stays empty.
///
///     Text(shortAddress(pkt.address))
func shortAddress(_ address: String) -> String {
    if address.isEmpty { return "" }
    return String(address.suffix(8)).uppercased()
}

/// How long ago a millisecond timestamp was: "3s", "2m", "1h", "4d". Empty for a timestamp that
/// was never set (zero or negative).
///
///     Text(agoText(seen.lastSeenMs))
func agoText(_ ms: Int64) -> String {
    if ms <= 0 { return "" }
    let nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    let elapsedMs: Int64 = max(Int64(0), nowMs - ms)
    let seconds: Int64 = elapsedMs / 1000
    if seconds < 60 { return "\(seconds)s" }
    let minutes: Int64 = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours: Int64 = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days: Int64 = hours / 24
    return "\(days)d"
}
