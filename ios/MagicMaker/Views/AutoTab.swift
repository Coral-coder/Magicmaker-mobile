import SwiftUI

struct AutoTab: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var ruleName = "My rule"
    @State private var selectedTrigger = PacketPatterns.systemTriggers[2].id
    @State private var selectedResponse = PacketPatterns.systemResponses[0].id

    private var learned: [MagicPacket] { vm.store.allLearnedPackets }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Auto-response", isOn: Binding(
                get: { vm.isAutoEnabled },
                set: { vm.setAutoEnabled($0) }
            ))
            .font(.headline)

            Text("When Auto is on, heard triggers replay the chosen response packet.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Rule name", text: $ruleName)
                .textFieldStyle(.roundedBorder)

            Picker("When I hear", selection: $selectedTrigger) {
                ForEach(PacketPatterns.buildTriggerOptions(learned: learned), id: \.id) { p in
                    Text(p.label).tag(p.id)
                }
            }

            Picker("Respond with", selection: $selectedResponse) {
                ForEach(PacketPatterns.buildResponseOptions(learned: learned), id: \.id) { p in
                    Text(p.label).tag(p.id)
                }
            }

            Button("Add rule") {
                let resp = PacketPatterns.systemResponses.first { $0.id == selectedResponse }?.defaultHex ?? ""
                vm.store.addAutoRule(name: ruleName, triggerId: selectedTrigger, responseId: selectedResponse, responseHex: resp)
            }
            .buttonStyle(.borderedProminent)

            List {
                ForEach(vm.store.autoRules) { rule in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { rule.enabled },
                            set: { vm.store.setAutoRuleEnabled(id: rule.id, enabled: $0) }
                        )) {
                            VStack(alignment: .leading) {
                                Text(rule.name).font(.subheadline.bold())
                                Text(rule.triggerPatternId).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { vm.store.deleteAutoRule(id: rule.id) } label: { Text("Delete") }
                    }
                }
            }
        }
        .padding(8)
    }
}
