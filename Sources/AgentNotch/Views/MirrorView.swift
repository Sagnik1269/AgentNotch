import AVFoundation
import SwiftUI

/// Front camera preview, mirrored, for a quick look before a call. The camera runs only while
/// this view is on screen (the green light turns off as soon as the mirror closes).
struct MirrorView: View {
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            switch access {
            case .authorized:
                CameraPreview()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            case .notDetermined:
                message(icon: "camera", "Allow camera access to use the mirror") {
                    AVCaptureDevice.requestAccess(for: .video) { _ in
                        DispatchQueue.main.async { access = AVCaptureDevice.authorizationStatus(for: .video) }
                    }
                }
            default:
                message(icon: "video.slash", "Camera access is off") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            Button(access == .notDetermined ? "Allow…" : "Open Privacy Settings…", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchAlert.Tint.blue.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}

private struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView() }
    func updateNSView(_ nsView: CameraPreviewView, context: Context) {}
    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: ()) { nsView.stop() }
}

final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let previewLayer: AVCaptureVideoPreviewLayer
    private static let queue = DispatchQueue(label: "agentnotch.mirror")

    override init(frame: NSRect) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    private func configure() {
        let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                                      position: .unspecified).devices.first
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        session.commitConfiguration()
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        let session = session
        Self.queue.async { session.startRunning() }
    }

    func stop() {
        let session = session
        Self.queue.async { session.stopRunning() }
    }
}
