import AVFoundation
import SwiftUI
import UIKit

/// Camera QR scanner for `codeman://connect?url=…&name=…`.
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    @State private var permission: PermissionState = .checking

    private enum PermissionState {
        case checking
        case granted
        case denied
    }

    var body: some View {
        NavigationStack {
            Group {
                switch permission {
                case .checking:
                    ProgressView()
                case .granted:
                    ScannerRepresentable(onScan: onScan)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) {
                            Text("Point the camera at the QR code in Codeman's settings.")
                                .font(.footnote)
                                .padding(12)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 24)
                        }
                case .denied:
                    ContentUnavailableView {
                        Label("Camera access needed", systemImage: "camera.badge.ellipsis")
                    } description: {
                        Text("Allow camera access in Settings to scan a Codeman QR code, or type the address instead.")
                    } actions: {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open Settings", destination: url)
                        }
                    }
                }
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task { await requestAccess() }
    }

    private func requestAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .granted
        case .notDetermined:
            permission = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default:
            permission = .denied
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onScan = onScan
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    /// `AVCaptureSession` is not `Sendable`. Every touch of it outside `configure()` happens on
    /// `sessionQueue`, which is the serial owner of its start/stop lifecycle, so the box states
    /// that invariant rather than silencing the compiler with `@preconcurrency`.
    private let sessionBox: CaptureSessionBox
    private var session: AVCaptureSession { sessionBox.session }
    private let sessionQueue = DispatchQueue(label: "cloud.creature.codeman.native.qr-session")

    override init(nibName: String?, bundle: Bundle?) {
        sessionBox = CaptureSessionBox()
        super.init(nibName: nibName, bundle: bundle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used — this controller is created in code.") }
    private var preview: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !session.isRunning else { return }
        // `startRunning` blocks, and the docs are explicit that it must not run on the main
        // thread. A plain dispatch rather than a `Task`: `AVCaptureSession` is not `Sendable`, so
        // handing it to a concurrent task is exactly the data race Swift 6 flags. This queue is
        // the session's own serial owner for start/stop.
        sessionQueue.async { [sessionBox] in sessionBox.session.startRunning() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [sessionBox] in
            if sessionBox.session.isRunning { sessionBox.session.stopRunning() }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
    }

    /// `AVCaptureMetadataOutputObjectsDelegate` is not main-actor isolated, but the output is
    /// configured with `queue: .main`, so this genuinely runs on the main thread. `nonisolated`
    /// plus `assumeIsolated` states that contract to the compiler instead of hopping through an
    /// async `Task`, which would let a second frame arrive before `hasScanned` is set.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Read the payload out here: `[AVMetadataObject]` is not Sendable, so the array itself
        // must not cross into the isolated closure — the extracted `String` is.
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else { return }

        MainActor.assumeIsolated {
            handleScan(value)
        }
    }

    private func handleScan(_ value: String) {
        guard !hasScanned else { return }
        hasScanned = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(value)
    }
}


/// Carries the capture session across the serial queue boundary.
///
/// Unchecked because `AVCaptureSession` predates `Sendable` and cannot be annotated here; the
/// safety argument is the queue discipline documented on `ScannerController.sessionBox`.
private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}
