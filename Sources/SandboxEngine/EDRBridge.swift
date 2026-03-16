import Foundation
import Virtualization

private let edrDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// An HTTP trace event captured from the guest browser via CDP Network domain.
public struct EDREvent: Codable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Double
    public let method: String
    public let url: String
    public var statusCode: Int?
    public var duration: Double?
    public var requestHeaders: [String: String]?
    public var responseHeaders: [String: String]?
    public var postData: String?
    public var responseBody: String?
    public var responseBodyTruncated: Bool?
    public var mimeType: String?
    public var initiator: String?
    public var tabId: Int?
    public var errorText: String?
    public var hostname: String?
    public var documentUrl: String?
    public var frameUrl: String?
    public var navType: String?
    public var redirectFrom: String?
    public var formFields: [FormFieldSnapshot]?

    public struct FormFieldSnapshot: Codable, Sendable {
        public let name: String
        public let type: String
        public let value: String

        public init(name: String, type: String, value: String) {
            self.name = name
            self.type = type
            self.value = value
        }
    }

    public init(
        id: String,
        timestamp: Double,
        method: String,
        url: String,
        statusCode: Int? = nil,
        duration: Double? = nil,
        requestHeaders: [String: String]? = nil,
        responseHeaders: [String: String]? = nil,
        postData: String? = nil,
        responseBody: String? = nil,
        responseBodyTruncated: Bool? = nil,
        mimeType: String? = nil,
        initiator: String? = nil,
        tabId: Int? = nil,
        errorText: String? = nil,
        hostname: String? = nil,
        documentUrl: String? = nil,
        frameUrl: String? = nil,
        navType: String? = nil,
        redirectFrom: String? = nil,
        formFields: [FormFieldSnapshot]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.duration = duration
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.postData = postData
        self.responseBody = responseBody
        self.responseBodyTruncated = responseBodyTruncated
        self.mimeType = mimeType
        self.initiator = initiator
        self.tabId = tabId
        self.errorText = errorText
        self.hostname = hostname
        self.documentUrl = documentUrl
        self.frameUrl = frameUrl
        self.navType = navType
        self.redirectFrom = redirectFrom
        self.formFields = formFields
    }
}

/// Receives HTTP trace events from the guest VM over vsock and stores them in SQLite.
///
/// Protocol: newline-delimited JSON on vsock port 5900.
///
/// Each line is a JSON-encoded ``EDREvent``. Events are persisted to a temporary
/// SQLite database via ``EDRStore``.
@MainActor
public final class EDRBridge: NSObject, @unchecked Sendable {
    private static let edrPort: UInt32 = 5900

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: EDRListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?

    /// SQLite-backed event storage.
    public private(set) var store: EDRStore

    /// Called on the main queue whenever a new event is received.
    public var onNewEvent: ((EDREvent) -> Void)?

    /// Current trace events (oldest first).
    public var traceEvents: [EDREvent] { store.queryEvents(filter: .all) }

    /// Return events with a timestamp strictly greater than the given value.
    public func eventsSince(timestamp: Double) -> [EDREvent] {
        return store.queryEvents(filter: EDRFilter(timeStart: timestamp))
    }

    /// Remove all stored events and recreate the database.
    public func clearTrace() {
        store.destroy()
    }

    /// Serialize all stored events as a JSON array.
    public func exportAsJSON() -> Data {
        store.exportAsJSON()
    }

    /// Copy the SQLite database file to the given URL.
    public func exportDatabase(to url: URL) throws {
        try store.exportDatabase(to: url)
    }

    /// Return all distinct hostnames seen in events.
    public func distinctHostnames() -> [String] {
        store.distinctHostnames()
    }

    // MARK: - Lifecycle

    public init(socketDevice: VZVirtioSocketDevice, sessionID: String = UUID().uuidString) {
        self.socketDevice = socketDevice
        self.store = EDRStore(sessionID: sessionID)
        super.init()

        if edrDebug { print("[EDR] init: setting up vsock listener on port \(Self.edrPort)") }

        let delegate = EDRListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.edrPort)
    }

    public func stop() {
        if edrDebug { print("[EDR] stop") }
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.edrPort)
        connection = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if edrDebug { print("[EDR] guest connected (fd=\(conn.fileDescriptor))") }

        readSource?.cancel()
        connection = conn

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var pendingData = Data()

        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                if edrDebug { print("[EDR] connection closed") }
                source.cancel()
                return
            }
            pendingData.append(contentsOf: buf[0..<n])

            // Cap buffer to prevent abuse (4 MB — events can carry response bodies)
            if pendingData.count > 4_194_304 {
                if edrDebug { print("[EDR] buffer overflow, disconnecting") }
                source.cancel()
                return
            }

            while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pendingData[pendingData.startIndex..<newlineIndex]
                pendingData = Data(pendingData[(newlineIndex + 1)...])

                if !lineData.isEmpty {
                    self?.handleMessage(Data(lineData))
                }
            }
        }

        source.setCancelHandler { [weak self] in
            if edrDebug { print("[EDR] dispatch source cancelled") }
            self?.readSource = nil
            self?.connection = nil
        }

        readSource = source
        source.activate()
    }

    private func handleMessage(_ data: Data) {
        let decoder = JSONDecoder()
        guard let event = try? decoder.decode(EDREvent.self, from: data) else {
            if edrDebug { print("[EDR] ignoring invalid message (\(data.count) bytes)") }
            return
        }

        if edrDebug { print("[EDR] \(event.method) \(event.url) → \(event.statusCode.map(String.init) ?? "pending")") }

        store.insert(event: event)

        onNewEvent?(event)
    }
}

// MARK: - Listener delegate

private final class EDRListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if edrDebug { print("[EDR] listener: accepting connection") }
        onConnection(connection)
        return true
    }
}
