import SwiftUI

// AUTO tab: arm auto-response, build a rule (one trigger, a stack of responses sent in order)
// and manage the saved rules. Port of Android `AutoTab` in `MagicMakerScreens.kt`.

/// Android starts the builder on the third system trigger ("Any starlight wand") and the second
/// system response ("Vibrate band").
private let autoDefaultTriggerId: String = PacketPatterns.systemTriggers.count > 2
    ? PacketPatterns.systemTriggers[2].id
    : "starlight"
private let autoDefaultResponseId: String = PacketPatterns.systemResponses.count > 1
    ? PacketPatterns.systemResponses[1].id
    : "resp_vibrate"

/// Which option list the picker sheet shows.
private enum AutoPickerKind: String, Identifiable {
    case trigger
    case response

    var id: String { rawValue }
}

/// The trigger and response options for the current library, with lookups by id. Built off the
/// main thread: the library can hold thousands of packets and each one is an option.
private struct AutoOptionLists {
    let triggers: [PacketPattern]
    let responses: [PacketPattern]
    /// First option wins for a repeated id, like Kotlin's `firstOrNull`.
    let triggerLabels: [String: String]
    let responseById: [String: PacketPattern]

    static let empty = AutoOptionLists(
        triggers: [],
        responses: [],
        triggerLabels: [:],
        responseById: [:]
    )
}

private func autoBuildOptions(userPresets: [MagicPacket], learned: [MagicPacket]) -> AutoOptionLists {
    let triggers: [PacketPattern] = PacketPatterns.buildTriggerOptions(userPresets: userPresets, learned: learned)
    let responses: [PacketPattern] = PacketPatterns.buildResponseOptions(userPresets: userPresets, learned: learned)
    var triggerLabels: [String: String] = [:]
    triggerLabels.reserveCapacity(triggers.count)
    for option in triggers where triggerLabels[option.id] == nil {
        triggerLabels[option.id] = option.label
    }
    var responseById: [String: PacketPattern] = [:]
    responseById.reserveCapacity(responses.count)
    for option in responses where responseById[option.id] == nil {
        responseById[option.id] = option
    }
    return AutoOptionLists(
        triggers: triggers,
        responses: responses,
        triggerLabels: triggerLabels,
        responseById: responseById
    )
}

// MARK: - Screen

struct AutoScreen: View {
    @EnvironmentObject var store: MagicStore

    @State private var ruleName: String = "My rule"
    @State private var triggerId: String = autoDefaultTriggerId
    @State private var pickResponseId: String = autoDefaultResponseId
    @State private var responseStack: [String] = []
    @State private var options: AutoOptionLists = AutoOptionLists.empty
    @State private var optionsGeneration: Int = 0
    @State private var picker: AutoPickerKind? = nil
    /// The list the open picker shows, fixed while it is open so rows do not move under the
    /// finger as packets are learned.
    @State private var pickerOptions: [PacketPattern] = []
    @State private var deleteRequest: DeleteRequest? = nil

    init() {}

    var body: some View {
        content
            .background(MMTheme.navy)
            .confirmDelete($deleteRequest)
            .sheet(item: $picker) { kind in
                pickerSheet(kind)
            }
            .onAppear {
                reloadOptions()
            }
            .onChange(of: store.revision) { _, _ in
                reloadOptions()
            }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                AutoArmHeader()
                ruleNameField
                triggerField
                responseField
                if !responseStack.isEmpty {
                    stackBlock
                }
                addRuleButton
                rulesBlock
            }
            .padding(6)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Rule builder

    private var ruleNameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            AutoFieldCaption(text: "Rule name")
            TextField("Rule name", text: $ruleName)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .padding(8)
                .background(MMTheme.panel)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
                .autocorrectionDisabled()
                .submitLabel(.done)
        }
    }

    private var triggerField: some View {
        AutoPickerField(caption: "When I hear", value: triggerLabel(triggerId)) {
            openPicker(.trigger)
        }
    }

    private var responseField: some View {
        AutoPickerField(caption: "Add response to stack", value: responseLabel(pickResponseId)) {
            openPicker(.response)
        }
    }

    private var stackBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            AutoFieldCaption(text: "Stack (\(responseStack.count))")
            ForEach(responseStack.indices, id: \.self) { index in
                stackRow(index: index)
            }
        }
    }

    private func stackRow(index: Int) -> some View {
        let id: String = index < responseStack.count ? responseStack[index] : ""
        let text: String = "\(index + 1). " + responseLabel(id)
        return HStack(spacing: 6) {
            Text(text)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button {
                removeFromStack(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MMTheme.textDim)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove")
        }
    }

    private var addRuleButton: some View {
        MMPrimaryButton(title: "Add rule", enabled: !responseStack.isEmpty) {
            addRule()
        }
        .padding(.top, 2)
    }

    // MARK: Rules

    private var rules: [AutoResponseRule] {
        _ = store.revision
        return store.autoRules
    }

    private var rulesBlock: some View {
        let list: [AutoResponseRule] = rules
        return VStack(alignment: .leading, spacing: 2) {
            Text("Rules (\(list.count))".uppercased())
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
            if list.isEmpty {
                Text("NO RULES — CONFIGURE STACK ABOVE")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
            } else {
                ForEach(list) { rule in
                    ruleRow(rule)
                }
            }
        }
        .padding(.top, 6)
    }

    private func ruleRow(_ rule: AutoResponseRule) -> some View {
        let ruleId: Int64 = rule.id
        return AutoRuleRow(
            rule: rule,
            onToggle: { on in
                store.setAutoRuleEnabled(id: ruleId, enabled: on)
            },
            onDelete: {
                askDelete(rule)
            }
        )
    }

    // MARK: Picker

    @ViewBuilder
    private func pickerSheet(_ kind: AutoPickerKind) -> some View {
        switch kind {
        case .trigger:
            AutoOptionPickerSheet(
                title: "When I hear",
                options: pickerOptions,
                onPick: { option in pickTrigger(option) },
                onCancel: { picker = nil }
            )
        case .response:
            AutoOptionPickerSheet(
                title: "Add response to stack",
                options: pickerOptions,
                onPick: { option in pickResponse(option) },
                onCancel: { picker = nil }
            )
        }
    }

    private func openPicker(_ kind: AutoPickerKind) {
        switch kind {
        case .trigger:
            pickerOptions = options.triggers.isEmpty ? PacketPatterns.systemTriggers : options.triggers
        case .response:
            pickerOptions = options.responses.isEmpty ? PacketPatterns.systemResponses : options.responses
        }
        picker = kind
    }

    private func pickTrigger(_ option: PacketPattern) {
        triggerId = option.id
        picker = nil
    }

    private func pickResponse(_ option: PacketPattern) {
        pickResponseId = option.id
        if !responseStack.contains(option.id) {
            responseStack.append(option.id)
        }
        picker = nil
    }

    // MARK: Actions

    private func removeFromStack(at index: Int) {
        guard index >= 0, index < responseStack.count else { return }
        var next: [String] = responseStack
        next.remove(at: index)
        responseStack = next
    }

    /// The stack's packets in order; a response with no packet of its own is left out of the
    /// hexes but keeps its id, as on Android.
    private func addRule() {
        if responseStack.isEmpty { return }
        var hexes: [String] = []
        for id in responseStack {
            let hex: String = responseOption(id)?.defaultHex ?? ""
            if !hex.isEmpty {
                hexes.append(hex)
            }
        }
        store.addAutoRule(name: ruleName, triggerId: triggerId, responseIds: responseStack, responseHexes: hexes)
        responseStack = []
    }

    private func askDelete(_ rule: AutoResponseRule) {
        let ruleId: Int64 = rule.id
        deleteRequest = DeleteRequest(title: "Delete auto rule?", label: rule.name) {
            store.deleteAutoRule(id: ruleId)
        }
    }

    // MARK: Options

    private func reloadOptions() {
        let presets: [MagicPacket] = store.customPresets
        let learned: [MagicPacket] = store.allLearnedPackets
        optionsGeneration += 1
        let generation: Int = optionsGeneration
        Task { @MainActor in
            let built: AutoOptionLists = await Task.detached(priority: .userInitiated) { () -> AutoOptionLists in
                autoBuildOptions(userPresets: presets, learned: learned)
            }.value
            applyOptions(built, generation: generation)
        }
    }

    private func applyOptions(_ built: AutoOptionLists, generation: Int) {
        // A newer read is on its way; this one is already out of date.
        if generation != optionsGeneration { return }
        options = built
    }

    /// The label Android shows for a trigger id, or the id itself when no option has it.
    private func triggerLabel(_ id: String) -> String {
        if let label = options.triggerLabels[id] {
            return label
        }
        if let system = PacketPatterns.systemTriggers.first(where: { $0.id == id }) {
            return system.label
        }
        return id
    }

    private func responseOption(_ id: String) -> PacketPattern? {
        if let option = options.responseById[id] {
            return option
        }
        return PacketPatterns.systemResponses.first(where: { $0.id == id })
    }

    private func responseLabel(_ id: String) -> String {
        responseOption(id)?.label ?? id
    }
}

// MARK: - Pieces

/// The title, the arm switch and the auto counters. Kept apart from the screen so the counters
/// can refresh with every heard packet without redrawing the rule builder.
private struct AutoArmHeader: View {
    @EnvironmentObject var scan: ScanEngine

    init() {}

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AUTO-RESPONSE")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                Text("TRIGGER → STACKED TX")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                Text(counterText)
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: armBinding)
                .labelsHidden()
                .tint(MMTheme.cyan)
                .accessibilityLabel("Auto-response")
        }
    }

    private var counterText: String {
        let heard: Int = scan.packetsHeard
        let sent: Int = scan.autoResponsesSent
        return "RX:\(heard) | TX-AUTO:\(sent)"
    }

    private var armBinding: Binding<Bool> {
        Binding(
            get: { scan.autoEnabled },
            set: { on in scan.setAuto(on) }
        )
    }
}

/// The small caption above a field (Android's text-field label).
private struct AutoFieldCaption: View {
    let text: String

    init(text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(MMTheme.techLabel(9))
            .foregroundStyle(MMTheme.cyanDim)
    }
}

/// A read-only field that opens a picker (Android's exposed dropdown).
private struct AutoPickerField: View {
    let caption: String
    let value: String
    let action: () -> Void

    init(caption: String, value: String, action: @escaping () -> Void) {
        self.caption = caption
        self.value = value
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AutoFieldCaption(text: caption)
            Button(action: action) {
                fieldBody
            }
            .buttonStyle(.plain)
        }
    }

    private var fieldBody: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MMTheme.textDim)
        }
        .padding(8)
        .background(MMTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(MMTheme.panelLine, lineWidth: 0.5))
        .contentShape(Rectangle())
    }
}

/// One saved rule: name, "trigger → n pkts", enable switch and delete.
private struct AutoRuleRow: View {
    let rule: AutoResponseRule
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    init(rule: AutoResponseRule, onToggle: @escaping (Bool) -> Void, onDelete: @escaping () -> Void) {
        self.rule = rule
        self.onToggle = onToggle
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(AutoRuleRow.describe(rule))
                    .font(MMTheme.techLabel(9))
                    .foregroundStyle(MMTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .tint(MMTheme.cyan)
            deleteButton
        }
        .padding(.vertical, 3)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { on in onToggle(on) }
        )
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 13))
                .foregroundStyle(MMTheme.error)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
    }

    /// Android's rule subtitle: "<trigger id> → n pkt(s)", counting a stackless rule as one.
    static func describe(_ rule: AutoResponseRule) -> String {
        let stackSize: Int = max(rule.responseHexes.count, 1)
        let plural: String = stackSize == 1 ? "" : "s"
        return "\(rule.triggerPatternId) → \(stackSize) pkt\(plural)"
    }
}

/// The option list of a picker. Lazy, because it can hold every packet in the library.
private struct AutoOptionPickerSheet: View {
    let title: String
    let options: [PacketPattern]
    let onPick: (PacketPattern) -> Void
    let onCancel: () -> Void

    init(
        title: String,
        options: [PacketPattern],
        onPick: @escaping (PacketPattern) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.options = options
        self.onPick = onPick
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 0.5)
            optionList
        }
        .background(MMTheme.navy)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(MMTheme.techHeader())
                .foregroundStyle(MMTheme.cyan)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("CANCEL") {
                onCancel()
            }
            .font(MMTheme.techLabel())
            .foregroundStyle(MMTheme.cyan)
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // By position, so a repeated id cannot confuse the list.
    private var optionList: some View {
        List {
            ForEach(options.indices, id: \.self) { index in
                optionRow(options[index])
                    .mmListRow()
            }
        }
        .mmListStyle()
    }

    private func optionRow(_ option: PacketPattern) -> some View {
        let text: String = option.label.isEmpty ? option.id : option.label
        return Button {
            onPick(option)
        } label: {
            Text(text)
                .font(MMTheme.techLabel(11))
                .foregroundStyle(MMTheme.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
