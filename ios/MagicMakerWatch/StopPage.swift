import SwiftUI

/// STOP PROGRAMS (docs/WATCH_APP.md 5.3 and 4.3): what runs by itself right now, and one button
/// that ends keep-awake, the TX and wand loops, the random show and any replay. AUTO stays armed.
struct StopPage: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.isLuminanceReduced) private var reduced: Bool
    @State private var confirming: Bool = false

    var body: some View {
        let ink: WatchInk = WatchInk(model.theme, reduced: reduced)
        let programs: [String] = runningPrograms
        let state: WatchRowState = model.stopState
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("PROGRAMS")
                    .font(WatchFont.smallBold)
                    .watchTone(.highlight, ink)
                if model.status == nil {
                    Text("NO DATA YET")
                        .font(WatchFont.small)
                        .watchTone(.dim, ink)
                } else if programs.isEmpty {
                    Text("NOTHING RUNNING")
                        .font(WatchFont.small)
                        .watchTone(.dim, ink)
                } else {
                    ForEach(Array(programs.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                        Text(item.element)
                            .font(WatchFont.small)
                            .watchTone(.text, ink)
                            .lineLimit(2)
                    }
                }
                stopButton(ink, busy: state == .sending)
                    .padding(.top, 4)
                resultLine(state, ink)
            }
            .padding(.horizontal, 4)
        }
        .alert("STOP PROGRAMS?", isPresented: $confirming) {
            Button("STOP", role: .destructive) {
                model.stopPrograms()
            }
            Button("CANCEL", role: .cancel) {
            }
        } message: {
            Text("Ends keep-awake, the TX and wand loops, the random show and any replay.")
        }
    }

    /// An inverted alarm block (a highlight block on a red-ish base), dimmed while the iPhone is
    /// away. A tap then reports why at once instead of asking to confirm first.
    private func stopButton(_ ink: WatchInk, busy: Bool) -> some View {
        let title: String = busy ? "STOPPING…" : "STOP PROGRAMS"
        return Button {
            if model.reachable {
                confirming = true
            } else {
                model.stopPrograms()
            }
        } label: {
            Text(title)
                .font(WatchFont.title)
                .foregroundStyle(Color.black)
                .watchLine()
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(ink.alarmFill, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(model.reachable ? 1.0 : 0.6)
    }

    /// The last stop's result: "STOPPED · VIA ESP32" (and the iPhone's note), or the error.
    @ViewBuilder
    private func resultLine(_ state: WatchRowState, _ ink: WatchInk) -> some View {
        switch state {
        case .idle, .sending:
            EmptyView()
        case .result(let ok, let text, _):
            Text(text)
                .font(WatchFont.smallBold)
                .watchTone(ok ? .highlight : .alarm, ink)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "ESP32: TX LOOP · 3S", "ANDROID: KEEP AWAKE", "IPHONE: RANDOM SHOW".
    private var runningPrograms: [String] {
        guard let status: WatchStatus = model.status else { return [] }
        var lines: [String] = []
        if let program: String = status.esp32.program, !program.isEmpty, program != "IDLE" {
            lines.append("ESP32: " + program)
        }
        if let program: String = status.android.program, !program.isEmpty, program != "IDLE" {
            lines.append("ANDROID: " + program)
        }
        for program in status.phone.programs where !program.isEmpty {
            lines.append("IPHONE: " + program)
        }
        return lines
    }
}
