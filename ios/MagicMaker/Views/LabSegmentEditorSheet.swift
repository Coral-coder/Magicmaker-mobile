import SwiftUI

/// What a tap on a packet-anatomy block hands the editor. The packet is captured as it was at the
/// tap, so the Lab re-rendering underneath (relay polls, heard packets) never moves the bytes out
/// from under an open editor.
struct LabSegmentEditTarget: Identifiable {
    let id: String
    let baseHex: String
    let segment: LabSegmentEditor.EditableSegment
    let builderType: LabPacketBuilder.LabPacketType
}

/// Edit one block of the packet: what it is and does, its valid values as a list (palette
/// swatches for colours, a composer for timing), packet-level actions, and manual hex checked
/// against the block's size. The preview at the top shows the whole candidate packet with the
/// changed bytes lit. Nothing is sent: Apply hands the packet back to the builder.
struct LabSegmentEditorSheet: View {
    let target: LabSegmentEditTarget
    let extended: Bool
    let onApply: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @State private var manual: String = ""
    @State private var manualError: String? = nil
    /// The draft came from the manual field, so emptying that field puts the packet back.
    @State private var draftFromManual: Bool = false

    init(
        target: LabSegmentEditTarget,
        extended: Bool,
        onApply: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.extended = extended
        self.onApply = onApply
        self.onCancel = onCancel
        self._draft = State(initialValue: target.baseHex)
    }

    private var seg: LabSegmentEditor.EditableSegment { target.segment }
    private var base: String { target.baseHex }

    /// Company ID with nothing to add, a malformed tail, or a block that could not be located.
    private var editable: Bool {
        !seg.fields.isEmpty || !seg.actions.isEmpty || seg.manual.allowed
    }

    private var canApply: Bool { draft != base && manualError == nil }

    private var cancelTitle: String { editable ? "Cancel" : "Close" }

    /// Fixed-size picks stack on the draft only while it still has the original's layout.
    private var sameSize: Bool { draft.count == base.count }

    var body: some View {
        NavigationStack {
            List {
                previewSection
                aboutSection
                if editable {
                    fieldSections
                    if !seg.actions.isEmpty {
                        actionSection
                    }
                    if seg.manual.allowed {
                        manualSection
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(MMTheme.navy)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(seg.segment.title.uppercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editable {
                        Button("Apply") { onApply(draft) }
                            .disabled(!canApply)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            LabSegmentPreview(
                base: base, draft: draft, segment: seg,
                extended: extended, builderType: target.builderType
            )
            .listRowBackground(MMTheme.panel)
        }
    }

    private var aboutSection: some View {
        Section {
            LabSegmentAboutRows(about: seg.about, segmentHex: seg.segment.hex)
        } header: {
            LabSegmentSectionHeader(title: "WHAT IT IS")
        }
    }

    private var fieldSections: some View {
        ForEach(0..<seg.fields.count, id: \.self) { index in
            fieldSection(seg.fields[index])
        }
    }

    private func fieldSection(_ field: LabSegmentEditor.Field) -> some View {
        let title: String = field.title.uppercased() + " · " + field.caption
        return Section {
            Text(field.about)
                .font(MMTheme.techLabel(10))
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(MMTheme.panel)
            fieldControls(field)
        } header: {
            LabSegmentSectionHeader(title: title)
        }
    }

    @ViewBuilder
    private func fieldControls(_ field: LabSegmentEditor.Field) -> some View {
        switch field.kind {
        case .timing:
            LabTimingComposer(value: currentByte(field), onPick: { (b: Int) -> Void in setByte(field, b) })
            optionRows(field)
        case .rgbChannel:
            LabRGBChannelRow(value: currentByte(field), onPick: { (b: Int) -> Void in setByte(field, b) })
        default:
            if field.options.isEmpty {
                Text("No preset values for this one: type a new value in MANUAL HEX below.")
                    .font(MMTheme.techLabel(10))
                    .foregroundStyle(MMTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(MMTheme.panel)
            }
            optionRows(field)
        }
    }

    private func optionRows(_ field: LabSegmentEditor.Field) -> some View {
        let reference: String = referenceHex(field)
        return ForEach(0..<field.options.count, id: \.self) { index in
            let option: LabSegmentEditor.Option = field.options[index]
            LabSegmentOptionRow(
                option: option,
                isCurrent: LabSegmentEditor.isCurrent(reference, field: field, option: option),
                onPick: { pick(field, option) }
            )
        }
    }

    private var actionSection: some View {
        Section {
            ForEach(0..<seg.actions.count, id: \.self) { index in
                LabSegmentActionRow(
                    action: seg.actions[index],
                    isCurrent: draft == seg.actions[index].hex,
                    onPick: { runAction(seg.actions[index]) }
                )
            }
        } header: {
            LabSegmentSectionHeader(title: "CHANGE THE PACKET")
        }
    }

    private var manualSection: some View {
        Section {
            TextField(manualPlaceholder, text: manualBinding)
                .font(MMTheme.techLabel(12))
                .foregroundStyle(MMTheme.cyan)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .listRowBackground(MMTheme.panel)
            Text(seg.manual.hint)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .listRowBackground(MMTheme.panel)
            if let problem = manualError {
                Text(problem)
                    .font(MMTheme.techLabel(10))
                    .foregroundStyle(MMTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(MMTheme.panel)
            }
        } header: {
            LabSegmentSectionHeader(title: "MANUAL HEX")
        }
    }

    // MARK: - Editing

    /// Where a field's current value is read from: the draft while it keeps the original layout
    /// (a shape always reads the draft, since picking one changes the layout), else the original.
    private func referenceHex(_ field: LabSegmentEditor.Field) -> String {
        if field.kind == .shape || sameSize { return draft }
        return base
    }

    private func currentByte(_ field: LabSegmentEditor.Field) -> Int {
        let bytes: [UInt8] = HexUtils.hexToBytes(referenceHex(field))
        if field.offset >= 0 && field.offset < bytes.count {
            return Int(bytes[field.offset])
        }
        guard let first = field.current.first else { return 0 }
        return Int(first)
    }

    private func clearManual() {
        manual = ""
        manualError = nil
        draftFromManual = false
    }

    /// A fixed-size pick lands on the draft, so timing and flags (or colour and flag) stack; a
    /// shape, a variable-length value or a pick after the layout changed starts from the original.
    private func pick(_ field: LabSegmentEditor.Field, _ option: LabSegmentEditor.Option) {
        clearManual()
        let fixed: Bool = field.kind != .shape && field.lengthByteOffset == nil && option.bytes.count == field.count
        let next: String?
        if fixed && sameSize {
            next = LabSegmentEditor.composing(draft, field: field, option: option)
        } else {
            next = LabSegmentEditor.applying(base, field: field, option: option)
        }
        if let h = next {
            draft = h
        }
    }

    private func setByte(_ field: LabSegmentEditor.Field, _ value: Int) {
        clearManual()
        let start: String = sameSize ? draft : base
        let byte: UInt8 = UInt8(value & 0xFF)
        if let h = LabSegmentEditor.replacing(start, offset: field.offset, count: 1, with: [byte], lengthByteOffset: nil) {
            draft = h
        }
    }

    private func runAction(_ action: LabSegmentEditor.Action) {
        clearManual()
        draft = action.hex
    }

    private var manualBinding: Binding<String> {
        Binding(
            get: { manual },
            set: { typed in manualChanged(typed) }
        )
    }

    /// Manual hex always replaces the block in the original packet; a refusal keeps the original.
    private func manualChanged(_ typed: String) {
        manual = typed
        let trimmed: String = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            manualError = nil
            if draftFromManual {
                draft = base
                draftFromManual = false
            }
            return
        }
        switch LabSegmentEditor.applyingManual(base, segment: seg, typed: typed) {
        case .applied(let h):
            draft = h
            manualError = nil
            draftFromManual = true
        case .invalid(let why):
            manualError = why
            draft = base
            draftFromManual = false
        }
    }

    /// The bytes manual hex replaces, as they are now.
    private var manualPlaceholder: String {
        let bytes: [UInt8] = HexUtils.hexToBytes(base)
        let rule: LabSegmentEditor.ManualRule = seg.manual
        var count: Int = rule.maxBytes
        if let lo = rule.lengthByteOffset, lo >= 0, lo < bytes.count {
            count = Int(bytes[lo])
        }
        let from: Int = rule.offset
        if from < 0 || count <= 0 || from + count > bytes.count {
            return seg.segment.hex.isEmpty ? "HEX" : seg.segment.hex
        }
        return HexUtils.bytesToHex(Array(bytes[from..<(from + count)]))
    }
}

// MARK: - Preview

/// The candidate packet: its bytes with the changed ones lit, what it is, the band preview, and
/// what the builder will make of it.
private struct LabSegmentPreview: View {
    let base: String
    let draft: String
    let segment: LabSegmentEditor.EditableSegment
    let extended: Bool
    let builderType: LabPacketBuilder.LabPacketType

    var body: some View {
        let summary: LabPacketSummary = LabPacketSummary(draft)
        VStack(alignment: .leading, spacing: 6) {
            Text(LabSegmentPreview.spacedHex(draft, highlight: highlight))
                .font(MMTheme.techLabel(12))
                .fixedSize(horizontal: false, vertical: true)
            Text(summary.headline.uppercased())
                .font(MMTheme.techHeader())
                .foregroundStyle(summary.toneColor)
                .lineLimit(2)
            Text(summary.details.joined(separator: " · ").uppercased())
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            warnings(summary)
            BandPreviewView(hex: draft, compact: true)
                .frame(height: 96)
            Text(builderLine)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(builderSwitches ? MMTheme.amber : MMTheme.cyanDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func warnings(_ summary: LabPacketSummary) -> some View {
        if let reject = summary.reject {
            Text(reject)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.error)
        }
        if let wand = LabSegmentEditor.newWandWarning(draft) {
            Text(wand)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The bytes that differ from the original, or the tapped block while nothing has changed.
    private var highlight: Range<Int>? {
        if let changed = LabSegmentEditor.changedRange(base, draft) {
            return changed
        }
        guard let offset = segment.about.offset else { return nil }
        return offset..<(offset + segment.about.count)
    }

    private var rebuiltType: LabPacketBuilder.LabPacketType? {
        LabSegmentEditor.builderState(draft, extended: extended)?.type
    }

    private var builderSwitches: Bool {
        guard let type = rebuiltType else { return false }
        return type != builderType
    }

    private var builderLine: String {
        guard let type = rebuiltType else { return "BUILDER: NOTHING TO BUILD" }
        if type == builderType {
            return "BUILDER: STAYS " + type.label.uppercased()
        }
        if type == .raw {
            return "BUILDER: SWITCHES TO RAW HEX (BYTE-FOR-BYTE)"
        }
        return "BUILDER: SWITCHES TO " + type.label.uppercased()
    }

    /// "83 01 E9 05 …" with the bytes in `highlight` bold cyan on a cyan wash, the rest dim.
    static func spacedHex(_ hex: String, highlight: Range<Int>?) -> AttributedString {
        let tokens: [String] = LabPacketTools.toBytes(hex)
        var out: AttributedString = AttributedString()
        var index: Int = 0
        for token in tokens {
            if index > 0 {
                var gap: AttributedString = AttributedString(" ")
                gap[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = MMTheme.textDim
                out.append(gap)
            }
            var piece: AttributedString = AttributedString(token)
            let lit: Bool = highlight?.contains(index) ?? false
            if lit {
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = MMTheme.cyan
                piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = MMTheme.cyan.opacity(0.18)
                piece[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = MMTheme.techHeader(12)
            } else {
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = MMTheme.textDim
            }
            out.append(piece)
            index += 1
        }
        return out
    }
}

// MARK: - What it is

private struct LabSegmentAboutRows: View {
    let about: LabSegmentEditor.About
    let segmentHex: String

    var body: some View {
        Group {
            Text(about.what)
                .font(MMTheme.techLabel(11))
                .foregroundStyle(MMTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("WHAT IT DOES: " + about.does)
                .font(MMTheme.techLabel(10))
                .foregroundStyle(MMTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                LabConfidenceBadge(confidence: about.confidence)
                Text(bytesLine)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.cyanDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("VALID: " + about.valid)
                .font(MMTheme.techLabel(9))
                .foregroundStyle(MMTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if !about.bits.isEmpty {
                Text(about.bits)
                    .font(MMTheme.techLabel(10))
                    .foregroundStyle(MMTheme.cyan)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listRowBackground(MMTheme.panel)
    }

    /// 1-based like the inspector's byte numbers.
    private var bytesLine: String {
        guard let offset = about.offset else {
            return "NOT FOUND IN THE PACKET · READ-ONLY"
        }
        let spaced: String = LabPacketTools.toBytes(segmentHex).joined(separator: " ")
        if about.count <= 1 {
            return "BYTE \(offset + 1) · " + spaced
        }
        return "BYTES \(offset + 1)–\(offset + about.count) · " + spaced
    }
}

private struct LabConfidenceBadge: View {
    let confidence: LabSegmentEditor.Confidence

    var body: some View {
        Text(confidence.rawValue.uppercased())
            .font(MMTheme.techLabel(9))
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(tone, lineWidth: 1))
    }

    private var tone: Color {
        switch confidence {
        case .proven: return MMTheme.cyan
        case .inferred: return MMTheme.cyanDim
        case .disputed, .unknown: return MMTheme.amber
        }
    }
}

// MARK: - Rows

private struct LabSegmentSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(MMTheme.techLabel(9))
            .foregroundStyle(MMTheme.cyanDim)
            .lineLimit(2)
    }
}

/// One value a field can take: swatch for colours, label, where it comes from, a checkmark on the
/// value the packet holds now.
private struct LabSegmentOptionRow: View {
    let option: LabSegmentEditor.Option
    let isCurrent: Bool
    let onPick: () -> Void

    var body: some View {
        Button {
            onPick()
        } label: {
            HStack(spacing: 10) {
                swatch
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(MMTheme.techLabel(12))
                        .foregroundStyle(isCurrent ? MMTheme.cyan : MMTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !option.note.isEmpty {
                        Text(option.note)
                            .font(MMTheme.techLabel(9))
                            .foregroundStyle(MMTheme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if option.experimental {
                    Text("EXPERIMENTAL")
                        .font(MMTheme.techLabel(8))
                        .foregroundStyle(MMTheme.amber)
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(MMTheme.cyan)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(isCurrent ? MMTheme.cyan.opacity(0.12) : MMTheme.panel)
    }

    @ViewBuilder
    private var swatch: some View {
        if let palette = option.palette {
            RoundedRectangle(cornerRadius: 3)
                .fill(starlightGlowColor(palette))
                .frame(width: 16, height: 16)
        }
    }
}

private struct LabSegmentActionRow: View {
    let action: LabSegmentEditor.Action
    let isCurrent: Bool
    let onPick: () -> Void

    var body: some View {
        Button {
            onPick()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.label.uppercased())
                        .font(MMTheme.techLabel(11))
                        .foregroundStyle(action.destructive ? MMTheme.error : MMTheme.cyan)
                        .fixedSize(horizontal: false, vertical: true)
                    if !action.note.isEmpty {
                        Text(action.note)
                            .font(MMTheme.techLabel(9))
                            .foregroundStyle(MMTheme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(MMTheme.cyan)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(isCurrent ? MMTheme.cyan.opacity(0.12) : MMTheme.panel)
    }
}

/// The timing byte built from its parts: always on, unit, fade-out seconds, count. Each control is
/// its own list row so a tap only reaches that control.
private struct LabTimingComposer: View {
    let value: Int
    let onPick: (Int) -> Void

    var body: some View {
        let parts: (alwaysOn: Bool, longUnit: Bool, fadeSeconds: Int, count: Int) = LabSegmentEditor.timingParts(value)
        Group {
            Toggle(isOn: alwaysOnBinding) {
                Text("Always on")
                    .font(MMTheme.techLabel(11))
                    .foregroundStyle(MMTheme.textPrimary)
            }
            .tint(MMTheme.cyan)
            Picker("Unit", selection: unitBinding) {
                Text("×1.5 s").tag(false)
                Text("×3.1 s").tag(true)
            }
            .pickerStyle(.segmented)
            Stepper(value: fadeBinding, in: 0...3) {
                Text("Fade-out \(parts.fadeSeconds) s")
                    .font(MMTheme.techLabel(11))
                    .foregroundStyle(MMTheme.textPrimary)
            }
            Stepper(value: countBinding, in: 0...15) {
                Text("Count \(parts.count)")
                    .font(MMTheme.techLabel(11))
                    .foregroundStyle(MMTheme.textPrimary)
            }
            Text(LabSegmentEditor.timingBits(value))
                .font(MMTheme.techLabel(10))
                .foregroundStyle(MMTheme.cyan)
                .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(MMTheme.panel)
    }

    private func compose(alwaysOn: Bool? = nil, longUnit: Bool? = nil, fade: Int? = nil, count: Int? = nil) {
        let p: (alwaysOn: Bool, longUnit: Bool, fadeSeconds: Int, count: Int) = LabSegmentEditor.timingParts(value)
        let byte: Int = LabSegmentEditor.timingByte(
            alwaysOn: alwaysOn ?? p.alwaysOn,
            longUnit: longUnit ?? p.longUnit,
            fadeSeconds: fade ?? p.fadeSeconds,
            count: count ?? p.count
        )
        onPick(byte)
    }

    private var alwaysOnBinding: Binding<Bool> {
        Binding(
            get: { LabSegmentEditor.timingParts(value).alwaysOn },
            set: { on in compose(alwaysOn: on) }
        )
    }

    private var unitBinding: Binding<Bool> {
        Binding(
            get: { LabSegmentEditor.timingParts(value).longUnit },
            set: { long in compose(longUnit: long) }
        )
    }

    private var fadeBinding: Binding<Int> {
        Binding(
            get: { LabSegmentEditor.timingParts(value).fadeSeconds },
            set: { seconds in compose(fade: min(max(seconds, 0), 3)) }
        )
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { LabSegmentEditor.timingParts(value).count },
            set: { n in compose(count: min(max(n, 0), 15)) }
        )
    }
}

/// An E908 colour channel: 0–63, sent as value × 2.
private struct LabRGBChannelRow: View {
    let value: Int
    let onPick: (Int) -> Void

    var body: some View {
        let level: Int = (value >> 1) & 0x3F
        HStack(spacing: 8) {
            Slider(value: levelBinding, in: 0...63, step: 1)
                .tint(MMTheme.cyan)
            Text("\(level) · " + DisneyTlv.hex2(value))
                .font(MMTheme.techLabel(10))
                .foregroundStyle(MMTheme.cyan)
                .frame(width: 64, alignment: .trailing)
        }
        .listRowBackground(MMTheme.panel)
    }

    private var levelBinding: Binding<Double> {
        Binding(
            get: { Double((value >> 1) & 0x3F) },
            set: { v in
                if !v.isFinite { return }
                let level: Int = min(max(Int(v.rounded()), 0), 63)
                onPick((level << 1) & 0xFF)
            }
        )
    }
}
