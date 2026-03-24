import AppKit
import Virtualization

/// Automatically pauses a VM when the session is idle and resumes it on interaction.
///
/// Idle is defined as ALL of the following being true for ``idleThreshold`` seconds:
///   - Window is not key (out of focus)
///   - No network traffic (packet count unchanged)
///   - No camera or microphone active
///
/// When the window becomes key again, the VM is resumed immediately.
///
/// This is a prototype for CPU savings research — sound monitoring is not
/// yet implemented (TODO: tap VZVirtioSoundDevice output stream).
@MainActor
public final class VMAutoSuspend {
    /// How long all idle conditions must hold before suspending.
    public static let idleThreshold: TimeInterval = 30

    /// How often to check idle conditions.
    private static let checkInterval: TimeInterval = 5

    private weak var vm: VZVirtualMachine?
    private weak var window: NSWindow?
    private var networkFilter: NetworkFilter?

    /// External check: is the webcam actively streaming?
    private var isWebcamStreaming = false
    /// External check: is the microphone enabled for this session?
    private let isMicrophoneEnabled: Bool

    private var isSuspended = false
    private var lastPacketCount: UInt64 = 0
    private var idleStart: Date?
    private var checkTimer: Timer?
    private var focusObservers: [NSObjectProtocol] = []

    /// Called when the VM is suspended or resumed. Bool = isSuspended.
    public var onStateChanged: ((Bool) -> Void)?

    public init(
        vm: VZVirtualMachine,
        window: NSWindow,
        networkFilter: NetworkFilter?,
        isMicrophoneEnabled: Bool
    ) {
        self.vm = vm
        self.window = window
        self.networkFilter = networkFilter
        self.isMicrophoneEnabled = isMicrophoneEnabled

        if let nf = networkFilter {
            lastPacketCount = nf.packetCount
        }

        // Observe window focus changes
        let nc = NotificationCenter.default
        focusObservers.append(
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWindowFocused() }
            }
        )
        focusObservers.append(
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWindowUnfocused() }
            }
        )

        // Start periodic idle check
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdle()
            }
        }

        print("[VMAutoSuspend] armed — idle threshold: \(Int(Self.idleThreshold))s")
    }

    nonisolated deinit {
        // Timer and observers are cleaned up via stop() called from BrowserSession.teardown()
    }

    public func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        for obs in focusObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        focusObservers.removeAll()

        // Resume if we're being torn down while suspended
        if isSuspended {
            resumeVM()
        }
    }

    /// Resume the VM if it is currently suspended (e.g. for an incoming API request).
    public func resumeForAPIRequest() {
        if isSuspended {
            resumeVM()
        }
    }

    /// Call this from WebcamBridge.onStreamingChanged to update webcam state.
    public func setWebcamStreaming(_ streaming: Bool) {
        isWebcamStreaming = streaming
        // If webcam just started, resume immediately
        if streaming && isSuspended {
            resumeVM()
        }
    }

    // MARK: - Focus handling

    private func handleWindowFocused() {
        idleStart = nil
        if isSuspended {
            resumeVM()
        }
    }

    private func handleWindowUnfocused() {
        // Start tracking idle time from now
        if idleStart == nil {
            idleStart = Date()
            lastPacketCount = networkFilter?.packetCount ?? 0
        }
    }

    // MARK: - Idle checking

    private func checkIdle() {
        guard vm != nil, let window else { return }
        guard !isSuspended else { return }

        // Condition 1: window must not be key
        guard !window.isKeyWindow else {
            idleStart = nil
            return
        }

        // Condition 2: no camera or microphone active
        if isWebcamStreaming || isMicrophoneEnabled {
            idleStart = nil
            return
        }

        // Condition 3: no network traffic
        let currentPacketCount = networkFilter?.packetCount ?? 0
        if currentPacketCount != lastPacketCount {
            // Traffic detected — reset idle timer
            lastPacketCount = currentPacketCount
            idleStart = Date()
            return
        }

        // All conditions met — check duration
        guard let start = idleStart else {
            idleStart = Date()
            lastPacketCount = currentPacketCount
            return
        }

        let idleDuration = Date().timeIntervalSince(start)
        if idleDuration >= Self.idleThreshold {
            suspendVM()
        }
    }

    // MARK: - VM suspend/resume

    private func suspendVM() {
        guard let vm, !isSuspended, vm.canPause else { return }
        isSuspended = true
        print("[VMAutoSuspend] suspending VM (idle for \(Int(Self.idleThreshold))s)")
        Task { @MainActor in
            do {
                try await vm.pause()
                self.onStateChanged?(true)
            } catch {
                print("[VMAutoSuspend] pause failed: \(error)")
                self.isSuspended = false
            }
        }
    }

    private func resumeVM() {
        guard let vm, isSuspended else { return }
        isSuspended = false
        idleStart = nil
        lastPacketCount = networkFilter?.packetCount ?? 0
        print("[VMAutoSuspend] resuming VM")
        Task { @MainActor in
            do {
                try await vm.resume()
                self.onStateChanged?(false)
            } catch {
                print("[VMAutoSuspend] resume failed: \(error)")
            }
        }
    }
}
