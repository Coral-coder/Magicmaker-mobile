import AVFoundation
import SwiftUI

struct PairingQRScannerView: View {
    var onScan: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            QRScannerRepresentable(onScan: onScan)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.cyan)
                        .padding()
                }
                Spacer()
                Text("SCAN ANDROID RELAY QR")
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                    .padding(8)
                    .background(MMTheme.panel.opacity(0.85))
                Spacer()
            }
        }
        .background(Color.black)
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScan,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue,
              !value.isEmpty else { return }
        didScan = true
        session.stopRunning()
        onScan?(value)
    }
}

enum PairingPayloadParser {
    static func parse(_ raw: String) -> AndroidPairingInfo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let info = AndroidPairingInfo.parse(json) {
            return info
        }
        if let info = AndroidPairingInfo.parseWiFiQR(trimmed) { return info }
        if trimmed.hasPrefix("WIFI:"),
           let inner = trimmed.components(separatedBy: "wifiQr").last?
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ": ,")),
           let info = AndroidPairingInfo.parseWiFiQR(inner) {
            return info
        }
        return nil
    }
}
