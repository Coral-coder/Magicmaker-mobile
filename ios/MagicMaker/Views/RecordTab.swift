import SwiftUI

struct RecordTab: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(vm.isRecording ? "Stop Scan" : "Scan") {
                    vm.toggleRecording()
                }
                .buttonStyle(.borderedProminent)
                Toggle("Auto", isOn: Binding(
                    get: { vm.isAutoEnabled },
                    set: { vm.setAutoEnabled($0) }
                ))
                .labelsHidden()
            }
            .padding(.top, 8)

            if let session = vm.activeSessionName {
                Text("Session: \(session)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Lock screen: enable Background App Refresh for MagicMaker")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Clear") { vm.clearLive() }
                Spacer()
                Text("\(vm.livePackets.count) packets")
                    .font(.caption)
            }

            List(vm.livePackets.reversed()) { rec in
                VStack(alignment: .leading, spacing: 4) {
                    Text(rec.label).font(.subheadline.bold())
                    Text(rec.hex).font(.caption.monospaced()).lineLimit(2)
                    Text("RSSI \(rec.rssi) · \(rec.libraryNote)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing) {
                    Button("Replay") { vm.playHex(rec.hex, label: rec.label) }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}
