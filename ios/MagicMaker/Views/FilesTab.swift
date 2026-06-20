import SwiftUI

struct FilesTab: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        List {
            Section("Scan sessions") {
                if vm.store.scanSessions.isEmpty {
                    Text("No CSV files yet — start Scan on Record tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.store.scanSessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.name)
                                .font(.caption.monospaced())
                        }
                        Spacer()
                        ShareLink(item: session.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                    }
                }
            }
            Section {
                Button("Refresh list") { vm.store.refreshSessions() }
            }
        }
        .onAppear { vm.store.refreshSessions() }
    }
}
