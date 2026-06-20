import SwiftUI

struct PresetsTab: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var section = 0

    var body: some View {
        VStack(spacing: 8) {
            Picker("Section", selection: $section) {
                Text("Shows").tag(0)
                Text("Anim").tag(1)
                Text("Colors").tag(2)
                Text("Raw").tag(3)
            }
            .pickerStyle(.segmented)

            List(currentPackets) { packet in
                Button {
                    vm.play(packet: packet)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(packet.label).font(.subheadline.bold())
                        if !packet.colors.isEmpty {
                            Text(packet.colors).font(.caption).foregroundStyle(.secondary)
                        }
                        if packet.typeInfo == "raw" {
                            Text(packet.hex).font(.caption2.monospaced()).lineLimit(2).foregroundStyle(.secondary)
                        }
                        if packet.wandVerified {
                            Text("Verified ✓").font(.caption2).foregroundStyle(.green)
                        }
                        if packet.userRecorded, section != 3 {
                            Text("Learned").font(.caption2).foregroundStyle(.blue)
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if packet.userRecorded {
                        Button(role: .destructive) {
                            deleteLearned(packet)
                        } label: { Text("Delete") }
                    }
                    if packet.typeInfo == "raw" {
                        Button {
                            vm.loadIntoLab(hex: packet.hex, label: packet.label)
                        } label: { Text("Lab") }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var currentPackets: [MagicPacket] {
        switch section {
        case 0: return vm.store.packets(for: .show)
        case 1: return vm.store.packets(for: .animation)
        case 2: return vm.store.packets(for: .color)
        default: return vm.store.packets(for: .unknown)
        }
    }

    private func deleteLearned(_ packet: MagicPacket) {
        switch packet.category {
        case .color: vm.store.deleteLearnedColor(id: packet.id)
        case .show, .animation: vm.store.deleteLearnedLibrary(id: packet.id)
        case .unknown: vm.store.deleteLearnedRaw(id: packet.id)
        }
    }
}
