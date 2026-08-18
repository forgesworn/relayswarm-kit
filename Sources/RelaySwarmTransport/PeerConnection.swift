import CDataChannel
import Foundation

/// One WebRTC peer connection over libdatachannel, non-trickle.
///
/// Non-trickle on purpose: the description is handed over once, complete
/// with candidates, when gathering finishes. Signalling over relays costs a
/// round trip per message, and a couple of hundred milliseconds of gathering
/// spent locally is cheaper than trickling candidates through them.
///
/// Callbacks arrive on libdatachannel's own threads; callers marshal.
public final class PeerConnection {
    public enum DescriptionType: String { case offer, answer }

    private let id: Int32
    private var retained: Unmanaged<PeerConnection>?
    private let lock = NSLock()
    private var channels = [Int32: DataChannel]()

    /// Fires once gathering completes, with the full local description.
    public var onGatheredDescription: (@Sendable (String, DescriptionType) -> Void)?
    /// Fires when the remote side opens a channel towards us.
    public var onDataChannel: (@Sendable (DataChannel) -> Void)?
    /// Fires when the connection fails or closes.
    public var onClosed: (@Sendable () -> Void)?

    public init(stunServers: [String] = ["stun:stun.l.google.com:19302"]) {
        var cStrings = stunServers.map { UnsafePointer<CChar>?(strdup($0)) }
        defer { cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var config = rtcConfiguration()
        memset(&config, 0, MemoryLayout<rtcConfiguration>.size)
        id = cStrings.withUnsafeMutableBufferPointer { buffer -> Int32 in
            config.iceServers = buffer.baseAddress
            config.iceServersCount = Int32(buffer.count)
            return rtcCreatePeerConnection(&config)
        }
        // The connection retains its wrapper until close(), because C
        // callbacks hold nothing but this pointer.
        retained = Unmanaged.passRetained(self)
        rtcSetUserPointer(id, retained!.toOpaque())

        rtcSetGatheringStateChangeCallback(id) { id, state, pointer in
            guard state == RTC_GATHERING_COMPLETE, let pointer else { return }
            let connection = Unmanaged<PeerConnection>.fromOpaque(pointer).takeUnretainedValue()
            var buffer = [CChar](repeating: 0, count: 65_536)
            guard rtcGetLocalDescription(id, &buffer, Int32(buffer.count)) >= 0 else { return }
            var typeBuffer = [CChar](repeating: 0, count: 64)
            let type = rtcGetLocalDescriptionType(id, &typeBuffer, Int32(typeBuffer.count)) >= 0
                ? DescriptionType(rawValue: String(cString: typeBuffer)) ?? .answer
                : .answer
            connection.onGatheredDescription?(String(cString: buffer), type)
        }
        rtcSetDataChannelCallback(id) { _, channelID, pointer in
            guard let pointer else { return }
            let connection = Unmanaged<PeerConnection>.fromOpaque(pointer).takeUnretainedValue()
            let channel = DataChannel(adopting: channelID)
            connection.lock.lock()
            connection.channels[channelID] = channel
            connection.lock.unlock()
            connection.onDataChannel?(channel)
        }
        rtcSetStateChangeCallback(id) { _, state, pointer in
            guard let pointer,
                  state == RTC_CLOSED || state == RTC_FAILED || state == RTC_DISCONNECTED else { return }
            let connection = Unmanaged<PeerConnection>.fromOpaque(pointer).takeUnretainedValue()
            connection.onClosed?()
        }
    }

    /// Open a channel towards the remote side; makes this peer the offerer.
    public func createDataChannel(_ label: String) -> DataChannel {
        let channel = DataChannel(adopting: rtcCreateDataChannel(id, label))
        lock.lock()
        channels[channel.id] = channel
        lock.unlock()
        return channel
    }

    public func setRemote(_ sdp: String, type: DescriptionType) {
        rtcSetRemoteDescription(id, sdp, type.rawValue)
    }

    public func close() {
        guard let held = retained else { return }
        retained = nil
        lock.lock()
        let open = channels.values
        channels.removeAll()
        lock.unlock()
        for channel in open { channel.close() }
        // Blocks until in-flight callbacks return, so releasing after is safe.
        rtcDeletePeerConnection(id)
        held.release()
    }

    deinit {
        if retained != nil {
            assertionFailure("PeerConnection leaked without close()")
        }
    }
}

/// One data channel: text out, text in, closure on close.
public final class DataChannel {
    let id: Int32
    private var retained: Unmanaged<DataChannel>?

    public var onOpen: (@Sendable () -> Void)?
    public var onText: (@Sendable (String) -> Void)?
    public var onClosed: (@Sendable () -> Void)?

    init(adopting id: Int32) {
        self.id = id
        retained = Unmanaged.passRetained(self)
        rtcSetUserPointer(id, retained!.toOpaque())
        rtcSetOpenCallback(id) { _, pointer in
            guard let pointer else { return }
            Unmanaged<DataChannel>.fromOpaque(pointer).takeUnretainedValue().onOpen?()
        }
        rtcSetMessageCallback(id) { _, message, size, pointer in
            // Negative size is this API's way of saying null-terminated text.
            guard let message, let pointer, size < 0 else { return }
            let channel = Unmanaged<DataChannel>.fromOpaque(pointer).takeUnretainedValue()
            channel.onText?(String(cString: message))
        }
        rtcSetClosedCallback(id) { _, pointer in
            guard let pointer else { return }
            Unmanaged<DataChannel>.fromOpaque(pointer).takeUnretainedValue().onClosed?()
        }
    }

    /// Send text; false when the channel is not open.
    @discardableResult
    public func send(_ text: String) -> Bool {
        rtcSendMessage(id, text, -1) >= 0
    }

    public func close() {
        guard let held = retained else { return }
        retained = nil
        rtcDeleteDataChannel(id)
        held.release()
    }

    deinit {
        if retained != nil {
            assertionFailure("DataChannel leaked without close()")
        }
    }
}
