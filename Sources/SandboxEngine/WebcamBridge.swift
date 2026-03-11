import AVFoundation
import Foundation
import Virtualization

private let wcDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Captures the host Mac's camera via AVFoundation and streams raw YUYV frames
/// to the guest VM over vsock (port 5400) for consumption by v4l2loopback.
///
/// Protocol (binary):
///   1. 12-byte header on connect: width(u32le) + height(u32le) + fps(u32le)
///   2. Per frame: size(u32le) + raw YUYV pixel data
///
/// Uses 640x480 YUYV (2 bytes/pixel) — ~18 MB/s at 30fps, well within vsock bandwidth.
@MainActor
public final class WebcamBridge: NSObject, @unchecked Sendable {
    private static let webcamPort: UInt32 = 5400
    private static let captureWidth = 640
    private static let captureHeight = 480
    private static let captureFPS = 30

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: WebcamListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var captureSession: AVCaptureSession?
    private var captureDelegate: CaptureDelegate?
    private var headerSent = false
    private let cameraID: String?

    /// Query the native resolution of a camera without starting capture.
    public static func queryCameraResolution(cameraID: String?) -> (width: Int, height: Int) {
        let camera: AVCaptureDevice?
        if let cameraID, let specific = AVCaptureDevice(uniqueID: cameraID) {
            camera = specific
        } else {
            camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        }
        guard let camera else { return (captureWidth, captureHeight) }
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        return (Int(dims.width), Int(dims.height))
    }

    /// - Parameter cameraID: AVCaptureDevice.uniqueID to use, or nil for default.
    public init(socketDevice: VZVirtioSocketDevice, cameraID: String? = nil) {
        self.socketDevice = socketDevice
        self.cameraID = cameraID
        super.init()

        if wcDebug { print("[Webcam] init: setting up vsock listener on port \(Self.webcamPort)") }

        let delegate = WebcamListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.webcamPort)
    }

    public func stop() {
        if wcDebug { print("[Webcam] stop") }
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        socketDevice?.removeSocketListener(forPort: Self.webcamPort)
        connection = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if wcDebug { print("[Webcam] guest connected (fd=\(conn.fileDescriptor))") }

        // Stop any existing capture
        captureSession?.stopRunning()
        captureSession = nil
        connection = conn
        headerSent = false

        startCapture(fd: conn.fileDescriptor)
    }

    private static func sendHeader(fd: Int32, width: Int, height: Int, fps: Int) {
        var data = Data(count: 12)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(width).littleEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: UInt32(height).littleEndian, toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: UInt32(fps).littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        _ = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
    }

    private func startCapture(fd: Int32) {
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480

        let camera: AVCaptureDevice?
        if let cameraID, let specific = AVCaptureDevice(uniqueID: cameraID) {
            camera = specific
        } else {
            camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        }
        guard let camera, let input = try? AVCaptureDeviceInput(device: camera) else {
            print("[Webcam] no camera available")
            return
        }

        guard session.canAddInput(input) else {
            print("[Webcam] cannot add camera input")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // Request YUYV (4:2:2) — universally supported by v4l2loopback
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8_yuvs
        ]
        output.alwaysDiscardsLateVideoFrames = true

        let queue = DispatchQueue(label: "io.bromure.webcam-capture", qos: .userInteractive)
        let delegate = CaptureDelegate(fd: fd) { [weak self] in
            DispatchQueue.main.async {
                self?.handleDisconnect()
            }
        }
        output.setSampleBufferDelegate(delegate, queue: queue)
        self.captureDelegate = delegate

        guard session.canAddOutput(output) else {
            print("[Webcam] cannot add video output")
            return
        }
        session.addOutput(output)

        // Configure frame rate — use the camera's native frame duration
        var actualFPS = Self.captureFPS
        if let range = camera.activeFormat.videoSupportedFrameRateRanges.first {
            actualFPS = Int(range.maxFrameRate)
            do {
                try camera.lockForConfiguration()
                camera.activeVideoMinFrameDuration = range.minFrameDuration
                camera.activeVideoMaxFrameDuration = range.minFrameDuration
                camera.unlockForConfiguration()
            } catch {
                print("[Webcam] failed to configure frame rate: \(error)")
            }
        }

        // Header is sent from the first captured frame (actual resolution may differ from preset)
        let bridge = self
        delegate.onFirstFrame = { width, height in
            guard !bridge.headerSent else { return }
            Self.sendHeader(fd: fd, width: width, height: height, fps: actualFPS)
            bridge.headerSent = true
            print("[Webcam] capture started at \(width)x\(height)@\(actualFPS)fps")
        }

        session.startRunning()
        self.captureSession = session
    }

    private func handleDisconnect() {
        if wcDebug { print("[Webcam] guest disconnected, stopping capture") }
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        connection = nil
        headerSent = false
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let fd: Int32
    private let onDisconnect: () -> Void
    private var disconnected = false
    var onFirstFrame: ((_ width: Int, _ height: Int) -> Void)?
    private var headerSent = false

    init(fd: Int32, onDisconnect: @escaping () -> Void) {
        self.fd = fd
        self.onDisconnect = onDisconnect
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !disconnected else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // YUYV is a single plane, 2 bytes per pixel
        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = width * 2  // YUYV = 2 bytes/pixel
        let frameSize = rowBytes * height

        // Send header with actual resolution on first frame
        if !headerSent {
            onFirstFrame?(width, height)
            headerSent = true
        }

        // Write frame size header (4 bytes LE)
        var sizeLE = UInt32(frameSize).littleEndian
        let sizeWritten = withUnsafeBytes(of: &sizeLE) { ptr in
            Darwin.write(fd, ptr.baseAddress!, 4)
        }
        if sizeWritten <= 0 {
            disconnected = true
            onDisconnect()
            return
        }

        // Write frame data — row by row if stride != row width (padding bytes)
        if bytesPerRow == rowBytes {
            // No padding, write entire buffer at once
            var total = 0
            while total < frameSize {
                let n = Darwin.write(fd, baseAddr + total, frameSize - total)
                if n <= 0 {
                    disconnected = true
                    onDisconnect()
                    return
                }
                total += n
            }
        } else {
            // Strip padding per row
            for row in 0..<height {
                let rowPtr = baseAddr + row * bytesPerRow
                var written = 0
                while written < rowBytes {
                    let n = Darwin.write(fd, rowPtr + written, rowBytes - written)
                    if n <= 0 {
                        disconnected = true
                        onDisconnect()
                        return
                    }
                    written += n
                }
            }
        }
    }
}

// MARK: - Listener delegate

private final class WebcamListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if wcDebug { print("[Webcam] listener: accepting connection") }
        onConnection(connection)
        return true
    }
}
