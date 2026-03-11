import CVmnet
import Foundation
import Virtualization

private let fwDebug = ProcessInfo.processInfo.environment["BROMURE_FW_DEBUG"] != nil

/// Host-side packet filter that sits between a VM and vmnet (shared/NAT mode).
///
/// Creates a vmnet interface in shared mode, a UNIX datagram socketpair, and
/// proxies Ethernet frames between them.  Outbound packets (VM → internet) are
/// inspected and dropped if they target the host's LAN subnet or other VMs on
/// the vmnet subnet.
///
/// Requires the `com.apple.developer.networking.vmnet` entitlement.
///
/// Usage:
///   let filter = NetworkFilter(networkInfo: info)
///   let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: filter.vmFileHandle)
///   net.attachment = attachment
public final class NetworkFilter: @unchecked Sendable {
    /// FileHandle for the VM side — pass to VZFileHandleNetworkDeviceAttachment.
    public let vmFileHandle: FileHandle

    private let hostFD: Int32
    private var vmnetInterface: interface_ref?
    private let vmnetQueue: DispatchQueue
    private let readQueue: DispatchQueue
    private var maxPacketSize: Int = 1600
    private var stopped = false

    /// When false, all packets are allowed through (pass-through mode).
    /// Set to true via `activateFiltering()` when a profile with LAN isolation is claimed.
    private var filteringActive = false

    /// Bitmap of 65536 ports — O(1) lookup. Built once at activation time.
    /// UDP/53 is always allowed regardless.
    private var portBitmap = [UInt64](repeating: 0, count: 1024)  // 1024 × 64 = 65536 bits
    private var portFilteringActive = false

    // Filter rules (all IPs in host byte order)
    private let lanSubnet: UInt32
    private let lanMask: UInt32
    private let gatewayIP: UInt32
    private let dnsServers: Set<UInt32>

    // vmnet subnet — learned from vmnet or defaulted to 192.168.64.0/24
    private var vmnetGateway: UInt32 = 0xC0A8_4001   // 192.168.64.1
    private let vmnetSubnet: UInt32  = 0xC0A8_4000    // 192.168.64.0
    private let vmnetMask: UInt32    = 0xFFFF_FF00    // /24

    // Well-known private ranges (for blocking all private IPs, not just the detected LAN)
    private static let privateRanges: [(UInt32, UInt32)] = [
        (0x0A00_0000, 0xFF00_0000),  // 10.0.0.0/8
        (0xAC10_0000, 0xFFF0_0000),  // 172.16.0.0/12
        (0xC0A8_0000, 0xFFFF_0000),  // 192.168.0.0/16
        (0xA9FE_0000, 0xFFFF_0000),  // 169.254.0.0/16 (link-local)
    ]

    /// Create a network filter with LAN isolation.
    ///
    /// Returns nil if vmnet cannot be started (missing entitlement or other error).
    public init?(networkInfo: HostNetworkInfo) {
        // Create datagram socketpair
        var fds: [Int32] = [0, 0]
        guard fds.withUnsafeMutableBufferPointer({ buf in
            Darwin.socketpair(AF_UNIX, SOCK_DGRAM, 0, buf.baseAddress!)
        }) == 0 else {
            print("[NetworkFilter] socketpair failed: \(errno)")
            return nil
        }

        let vmSideFD = fds[0]
        self.hostFD = fds[1]
        self.vmFileHandle = FileHandle(fileDescriptor: vmSideFD, closeOnDealloc: true)

        // Set socket buffer sizes for better throughput
        var bufSize: Int32 = 1024 * 1024
        setsockopt(vmSideFD, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(vmSideFD, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(hostFD, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(hostFD, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        // Store filter rules
        self.lanSubnet = networkInfo.subnet
        self.lanMask = networkInfo.subnetMask
        self.gatewayIP = networkInfo.gateway
        self.dnsServers = Set(networkInfo.dnsServers)

        self.vmnetQueue = DispatchQueue(label: "io.bromure.vmnet", qos: .userInteractive)
        self.readQueue = DispatchQueue(label: "io.bromure.vmnet-read", qos: .userInteractive)

        // Start vmnet interface in shared (NAT) mode
        guard startVmnet() else {
            Darwin.close(vmSideFD)
            Darwin.close(hostFD)
            return nil
        }

        if fwDebug { print("[NetworkFilter] vmnet proxy started (pass-through until activateFiltering())") }

        startProxy()
    }

    /// Activate LAN isolation filtering. Until this is called, all packets pass through.
    public func activateFiltering() {
        filteringActive = true
        if fwDebug {
            print("[NetworkFilter] LAN isolation ACTIVATED")
            print("[NetworkFilter] Rules:")
            print("[NetworkFilter]   ALLOW vmnet gateway \(HostNetworkInfo.formatIPv4(vmnetGateway))")
            print("[NetworkFilter]   ALLOW host gateway  \(HostNetworkInfo.formatIPv4(gatewayIP))")
            for dns in dnsServers {
                print("[NetworkFilter]   ALLOW DNS \(HostNetworkInfo.formatIPv4(dns)) port 53 only")
            }
            print("[NetworkFilter]   DENY  vmnet subnet  \(HostNetworkInfo.formatIPv4(vmnetSubnet))/\(Self.maskBits(vmnetMask))")
            print("[NetworkFilter]   DENY  detected LAN  \(HostNetworkInfo.formatIPv4(lanSubnet))/\(Self.maskBits(lanMask))")
            for (subnet, mask) in Self.privateRanges {
                print("[NetworkFilter]   DENY  private range \(HostNetworkInfo.formatIPv4(subnet))/\(Self.maskBits(mask))")
            }
            print("[NetworkFilter]   ALLOW everything else (internet)")
        }
    }

    /// Activate port restriction. Only the specified ports (plus UDP/53) will be allowed.
    /// Format: "80,443,8000-9000"
    public func activatePortFiltering(_ portsSpec: String) {
        let ranges = Self.parsePortRanges(portsSpec)
        guard !ranges.isEmpty else {
            if fwDebug { print("[NetworkFilter] Port filtering: no valid ports parsed from '\(portsSpec)', skipping") }
            return
        }
        // Build bitmap — 8 KB, O(1) lookup per packet
        portBitmap = [UInt64](repeating: 0, count: 1024)
        for range in ranges {
            for port in range {
                let p = Int(port)
                portBitmap[p >> 6] |= 1 << (p & 63)
            }
        }
        portFilteringActive = true
        if fwDebug {
            let desc = ranges.map { r in
                r.lowerBound == r.upperBound ? "\(r.lowerBound)" : "\(r.lowerBound)-\(r.upperBound)"
            }.joined(separator: ", ")
            print("[NetworkFilter] Port filtering ACTIVATED: allow \(desc) + UDP/53")
        }
    }

    /// Parse "80,443,8000-9000" into an array of ClosedRange<UInt16>.
    static func parsePortRanges(_ spec: String) -> [ClosedRange<UInt16>] {
        var ranges: [ClosedRange<UInt16>] = []
        for part in spec.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-") {
                let ends = trimmed.split(separator: "-", maxSplits: 1)
                if ends.count == 2,
                   let lo = UInt16(ends[0].trimmingCharacters(in: .whitespaces)),
                   let hi = UInt16(ends[1].trimmingCharacters(in: .whitespaces)),
                   lo <= hi {
                    ranges.append(lo...hi)
                }
            } else if let port = UInt16(trimmed) {
                ranges.append(port...port)
            }
        }
        return ranges
    }

    private func isPortAllowed(_ port: UInt16) -> Bool {
        let p = Int(port)
        return portBitmap[p >> 6] & (1 << (p & 63)) != 0
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        Darwin.close(hostFD)
        if let iface = vmnetInterface {
            vmnet_stop_interface(iface, vmnetQueue) { _ in }
            vmnetInterface = nil
        }
        if fwDebug { print("[NetworkFilter] stopped") }
    }

    deinit {
        if !stopped { stop() }
    }

    // MARK: - vmnet lifecycle

    private func startVmnet() -> Bool {
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(kVmnetSharedMode))

        let sem = DispatchSemaphore(value: 0)
        var success = false

        vmnetInterface = vmnet_start_interface(desc, vmnetQueue) { [weak self] status, params in
            if status == vmnet_return_t(rawValue: kVmnetSuccess) {
                success = true
                if let params, let self {
                    self.maxPacketSize = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))
                    if self.maxPacketSize == 0 { self.maxPacketSize = 1600 }
                    if fwDebug { print("[NetworkFilter] vmnet started, max packet size: \(self.maxPacketSize)") }
                }
            } else {
                print("[NetworkFilter] vmnet_start_interface failed: status \(status.rawValue)")
            }
            sem.signal()
        }
        sem.wait()

        return success && vmnetInterface != nil
    }

    // MARK: - Packet proxy

    private func startProxy() {
        guard let iface = vmnetInterface else { return }

        // vmnet → VM: register event callback for incoming packets
        vmnet_interface_set_event_callback(iface, interface_event_t(rawValue: kVmnetInterfacePacketsAvail), vmnetQueue) { [weak self] _, _ in
            self?.drainVmnetToVM()
        }

        // VM → vmnet: blocking read loop on a dedicated queue
        readQueue.async { [weak self] in
            self?.readVMLoop()
        }
    }

    /// Read all available packets from vmnet and forward to the VM.
    private func drainVmnetToVM() {
        guard let iface = vmnetInterface, !stopped else { return }

        let bufSize = maxPacketSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while !stopped {
            var iov = iovec(iov_base: buf, iov_len: bufSize)
            var count: Int32 = 1
            var pktSize = 0
            let ret = withUnsafeMutablePointer(to: &iov) { iovPtr in
                var pkt = vmpktdesc(vm_pkt_size: bufSize, vm_pkt_iov: iovPtr, vm_pkt_iovcnt: 1, vm_flags: 0)
                let r = vmnet_read(iface, &pkt, &count)
                pktSize = pkt.vm_pkt_size
                return r
            }
            guard ret == vmnet_return_t(rawValue: kVmnetSuccess), count > 0 else { break }

            let size = pktSize
            let n = Darwin.write(hostFD, buf, size)
            if n <= 0 { break }
        }
    }

    /// Blocking loop: read packets from the VM and forward to vmnet (with filtering).
    private func readVMLoop() {
        let bufSize = maxPacketSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while !stopped {
            let n = Darwin.read(hostFD, buf, bufSize)
            guard n > 0 else { break }

            // Filter outbound packets
            let rawBuf = UnsafeRawBufferPointer(start: buf, count: n)
            guard shouldAllowOutbound(rawBuf) else {
                if fwDebug { logDropped(rawBuf) }
                continue
            }

            guard let iface = vmnetInterface, !stopped else { break }
            var iov = iovec(iov_base: buf, iov_len: n)
            var count: Int32 = 1
            withUnsafeMutablePointer(to: &iov) { iovPtr in
                var pkt = vmpktdesc(vm_pkt_size: n, vm_pkt_iov: iovPtr, vm_pkt_iovcnt: 1, vm_flags: 0)
                vmnet_write(iface, &pkt, &count)
            }
        }
    }

    // MARK: - Packet inspection

    /// Check if an outbound packet (VM → network) should be allowed.
    private func shouldAllowOutbound(_ packet: UnsafeRawBufferPointer) -> Bool {
        guard filteringActive || portFilteringActive else { return true }
        guard packet.count >= 14 else { return true }

        let etherType = UInt16(packet[12]) << 8 | UInt16(packet[13])

        // ARP: check target protocol address (port filtering doesn't apply)
        if etherType == 0x0806 {
            guard filteringActive, packet.count >= 42 else { return true }
            let targetIP = readUInt32BE(packet, offset: 38)
            let allowed = isAllowedDestination(targetIP, dstPort: nil)
            if fwDebug && allowed { logAllowed("ARP", dst: targetIP, port: nil) }
            return allowed
        }

        // Only filter IPv4
        guard etherType == 0x0800, packet.count >= 34 else { return true }

        let dstIP = readUInt32BE(packet, offset: 30)

        // Parse transport header for destination port and protocol
        var dstPort: UInt16?
        let proto = packet[23]
        if proto == 6 || proto == 17 {  // TCP or UDP
            let ihl = Int(packet[14] & 0x0F) * 4
            let transportOffset = 14 + ihl
            if packet.count >= transportOffset + 4 {
                dstPort = UInt16(packet[transportOffset + 2]) << 8 | UInt16(packet[transportOffset + 3])
            }
        }

        // IP-level filtering (LAN isolation)
        if filteringActive && !isAllowedDestination(dstIP, dstPort: dstPort) {
            return false
        }

        // Port-level filtering
        if portFilteringActive, proto == 6 || proto == 17 {
            // UDP/53 (DNS) is always allowed
            if proto == 17 && dstPort == 53 {
                // pass through
            } else if let port = dstPort, !isPortAllowed(port) {
                return false
            }
        }

        if fwDebug { logAllowed(proto == 6 ? "TCP" : proto == 17 ? "UDP" : "IP", dst: dstIP, port: dstPort) }
        return true
    }

    /// Log allowed packets (first 20 only, to avoid flooding).
    private var allowedLogCount = 0
    private func logAllowed(_ proto: String, dst: UInt32, port: UInt16?) {
        guard allowedLogCount < 20 else {
            if allowedLogCount == 20 {
                print("[NetworkFilter] (suppressing further ALLOW logs)")
                allowedLogCount += 1
            }
            return
        }
        allowedLogCount += 1
        let portStr = port.map { ":\($0)" } ?? ""
        print("[NetworkFilter] ALLOW \(proto) → \(HostNetworkInfo.formatIPv4(dst))\(portStr)")
    }

    /// Determine if a destination IP is allowed.
    private func isAllowedDestination(_ ip: UInt32, dstPort: UInt16?) -> Bool {
        // Always allow vmnet gateway (needed for NAT routing)
        if ip == vmnetGateway { return true }

        // Always allow the host's default gateway
        if ip == gatewayIP { return true }

        // Allow DNS servers but only on port 53
        if dnsServers.contains(ip) {
            return dstPort == 53
        }

        // Deny anything in the vmnet subnet (inter-VM isolation)
        if (ip & vmnetMask) == vmnetSubnet { return false }

        // Deny the detected LAN subnet (covers public IP LANs too)
        if (ip & lanMask) == lanSubnet { return false }

        // Deny all RFC 1918 private addresses + link-local
        // This ensures LAN isolation even if the host switches networks
        for (subnet, mask) in Self.privateRanges {
            if (ip & mask) == subnet { return false }
        }

        // Allow everything else (internet)
        return true
    }

    // MARK: - Helpers

    private func readUInt32BE(_ buf: UnsafeRawBufferPointer, offset: Int) -> UInt32 {
        UInt32(buf[offset]) << 24 |
        UInt32(buf[offset + 1]) << 16 |
        UInt32(buf[offset + 2]) << 8 |
        UInt32(buf[offset + 3])
    }

    private func logDropped(_ packet: UnsafeRawBufferPointer) {
        guard packet.count >= 14 else { return }
        let etherType = UInt16(packet[12]) << 8 | UInt16(packet[13])
        if etherType == 0x0800, packet.count >= 34 {
            let srcIP = readUInt32BE(packet, offset: 26)
            let dstIP = readUInt32BE(packet, offset: 30)
            let proto = packet[23]
            var dstPort: UInt16?
            var portInfo = ""
            if (proto == 6 || proto == 17), packet.count >= 14 + Int(packet[14] & 0x0F) * 4 + 4 {
                let ihl = Int(packet[14] & 0x0F) * 4
                let tp = 14 + ihl
                dstPort = UInt16(packet[tp + 2]) << 8 | UInt16(packet[tp + 3])
                portInfo = " \(proto == 6 ? "TCP" : "UDP"):\(dstPort!)"
            }
            let reason = blockReason(dstIP, dstPort: dstPort, proto: proto)
            print("[NetworkFilter] BLOCKED \(HostNetworkInfo.formatIPv4(srcIP)) → \(HostNetworkInfo.formatIPv4(dstIP))\(portInfo) (\(reason))")
        } else if etherType == 0x0806, packet.count >= 42 {
            let targetIP = readUInt32BE(packet, offset: 38)
            let reason = blockReason(targetIP, dstPort: nil, proto: 0)
            print("[NetworkFilter] BLOCKED ARP → \(HostNetworkInfo.formatIPv4(targetIP)) (\(reason))")
        }
    }

    private func blockReason(_ ip: UInt32, dstPort: UInt16?, proto: UInt8) -> String {
        // Check IP-level reasons first
        if filteringActive {
            if dnsServers.contains(ip) && dstPort != 53 { return "DNS server, non-port-53" }
            if (ip & vmnetMask) == vmnetSubnet { return "vmnet subnet" }
            if (ip & lanMask) == lanSubnet { return "detected LAN \(HostNetworkInfo.formatIPv4(lanSubnet))/\(Self.maskBits(lanMask))" }
            for (subnet, mask) in Self.privateRanges {
                if (ip & mask) == subnet {
                    return "private range \(HostNetworkInfo.formatIPv4(subnet))/\(Self.maskBits(mask))"
                }
            }
        }
        // Check port-level reason
        if portFilteringActive, let port = dstPort, (proto == 6 || proto == 17) {
            if !(proto == 17 && port == 53) && !isPortAllowed(port) {
                return "port \(port) not in allowed list"
            }
        }
        return "unknown"
    }

    private static func maskBits(_ mask: UInt32) -> Int {
        var m = mask
        var bits = 0
        while m & 0x8000_0000 != 0 {
            bits += 1
            m <<= 1
        }
        return bits
    }
}
