import SwiftUI

struct LabTab: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var hex: String = ""
    @State private var label: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Experimental packet builder")
                    .font(.headline)

                relayCard
                setupCard

                TextField("Hex (8301…)", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Label (for raw library)", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                if let reason = HexUtils.legacyAdvertiseRejectReason(hex) {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }

                Button("Transmit") {
                    vm.store.saveLabHex(hex)
                    vm.store.saveLabLabel(label)
                    vm.playHex(hex, label: label.isEmpty ? "Lab" : label)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.remoteLinkReady)

                Button("Apply label to matching raw packet") {
                    vm.store.saveLabHex(hex)
                    vm.store.saveLabLabel(label)
                    vm.store.applyLabLabelToMatchingRaw()
                    vm.statusMessage = "Raw label updated"
                }
                .buttonStyle(.bordered)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Vibrate band") { vm.vibrateAndroid() }
                    .buttonStyle(.bordered)
                    .disabled(!vm.remoteLinkReady)

                Divider()
                randomShowCard
                Divider()
                newWandCard
            }
            .padding(12)
        }
        .onAppear {
            hex = vm.store.getLabHex()
            label = vm.store.getLabLabel()
            vm.refreshRelayStatus()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            vm.refreshRelayStatus()
        }
    }

    private var relayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transmit backend")
                .font(.caption.weight(.semibold))
            Picker("Backend", selection: Binding(
                get: { vm.relayBackend },
                set: { vm.setRelayBackend($0) }
            )) {
                ForEach(RelayBackend.allCases) { backend in
                    Text(backend.label).tag(backend)
                }
            }
            .pickerStyle(.menu)

            if vm.relayBackend == .androidWifi {
                TextField("Android IP (hotspot gateway)", text: Binding(
                    get: { vm.androidRelayIP },
                    set: { vm.saveAndroidRelayIP($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .keyboardType(.decimalPad)
                Text("Join Android hotspot on iPhone. Default gateway is often 192.168.43.1")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Status: \(vm.relayStatus)")
                    .font(.caption.weight(.semibold))
                Spacer()
                if vm.relayBackend.usesBleRelayLink || vm.relayBackend.usesWifiRelay {
                    Button("Retry") { vm.reconnectRelay() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                switch vm.relayBackend {
                case .esp32:
                    Text("ESP32 transmitter")
                        .font(.caption.weight(.semibold))
                    Text("1. Power on the MagicMaker ESP32 (USB or battery).")
                    Text("2. iPhone auto-connects — no pairing needed.")
                    Text("3. iPhone keeps scanning; the ESP32 does the transmitting.")
                case .androidBle:
                    Text("Android BLE GATT relay")
                        .font(.caption.weight(.semibold))
                    Text("1. Open MagicMaker on Android → Relay tab → BLE GATT.")
                    Text("2. Keep Android foreground service running (notification visible).")
                    Text("3. iPhone transmits via GATT to MagicMaker-Android.")
                case .androidWifi:
                    Text("Android WiFi hotspot relay")
                        .font(.caption.weight(.semibold))
                    Text("1. Android → Relay → WiFi hotspot mode.")
                    Text("2. Connect iPhone to that hotspot (WiFi only — no cellular routing issue on Android).")
                    Text("3. iPhone POSTs to http://<android-ip>:8765/transmit")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var randomShowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Random light show")
                .font(.caption.weight(.semibold))
            Text("Fires a surprise packet on a loop until stopped (runs while this screen is open).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Text("Interval").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1fs", vm.randomShowIntervalSec)).font(.caption2)
            }
            Slider(
                value: Binding(get: { vm.randomShowIntervalSec }, set: { vm.setRandomShowInterval($0) }),
                in: 0.5...30, step: 0.5
            )
            Button(vm.randomShowRunning ? "Stop show" : "Start show") {
                if vm.randomShowRunning { vm.stopRandomShow() } else { vm.startRandomShow() }
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.randomShowRunning ? .red : .accentColor)
            .disabled(!vm.remoteLinkReady)
            if vm.randomShowRunning, !vm.randomShowLabel.isEmpty {
                Text(vm.randomShowLabel.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var newWandCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Wand codes (\(NewWandCatalog.packets.count))")
                .font(.caption.weight(.semibold))
            Text("Tap a code (by last 2 bytes) to transmit through the current backend.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(NewWandCatalog.packets) { pkt in
                        Button {
                            vm.playHex(pkt.hex, label: pkt.label)
                        } label: {
                            HStack {
                                Text(String(pkt.hex.suffix(4)))
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(pkt.colors)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .frame(height: 240)
            .disabled(!vm.remoteLinkReady)
        }
    }
}
