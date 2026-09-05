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
///
/// Handlers may be installed after the event they want has already fired.
/// On loopback the whole handshake completes in a few milliseconds, which
/// is sooner than the caller's next line of Swift, so nothing here is
/// allowed to depend on assignment order: a gathered description or a
/// close that fired before its handler existed is replayed once when the
/// handler arrives, and channels the remote opened early queue until
/// onDataChannel is set.
public final class PeerConnection {
    public enum DescriptionType: String { case offer, answer }

    private let id: Int32
    private var retained: Unmanaged<PeerConnection>?
    private let lock = NSLock()
    private var channels = [Int32: DataChannel]()

    private var gathered: (String, DescriptionType)?
    private var gatherDelivered = false
    private var pendingChannels = [DataChannel]()
    private var drainingChannels = false
    private var closedEarly = false
    private var closeDelivered = false

    /// Fires once gathering completes, with the full local description.
    public var onGatheredDescription: (@Sendable (String, DescriptionType) -> Void)? {
        didSet { replayGatheredIfNeeded() }
    }
    /// Fires when the remote side opens a channel towards us.
    public var onDataChannel: (@Sendable (DataChannel) -> Void)? {
        didSet { flushPendingChannels() }
    }
    /// Fires when the connection fails or closes.
    public var onClosed: (@Sendable () -> Void)? {
        didSet { replayCloseIfNeeded() }
    }

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
            connection.didGather(String(cString: buffer), type)
        }
        rtcSetDataChannelCallback(id) { _, channelID, pointer in
            guard let pointer else { return }
            let connection = Unmanaged<PeerConnection>.fromOpaque(pointer).takeUnretainedValue()
            let channel = DataChannel(adopting: channelID)
            connection.lock.lock()
            connection.channels[channelID] = channel
            connection.lock.unlock()
            connection.didReceiveChannel(channel)
        }
        rtcSetStateChangeCallback(id) { _, state, pointer in
            guard let pointer,
                  state == RTC_CLOSED || state == RTC_FAILED || state == RTC_DISCONNECTED else { return }
            let connection = Unmanaged<PeerConnection>.fromOpaque(pointer).takeUnretainedValue()
            connection.didClose()
        }
    }

    private func didGather(_ sdp: String, _ type: DescriptionType) {
        lock.lock()
        gathered = (sdp, type)
        let handler = onGatheredDescription
        gatherDelivered = handler != nil
        lock.unlock()
        handler?(sdp, type)
    }

    private func replayGatheredIfNeeded() {
        lock.lock()
        guard let (sdp, type) = gathered, !gatherDelivered, let handler = onGatheredDescription else {
            lock.unlock()
            return
        }
        gatherDelivered = true
        lock.unlock()
        handler(sdp, type)
    }

    private func didReceiveChannel(_ channel: DataChannel) {
        lock.lock()
        guard let handler = onDataChannel, !drainingChannels, pendingChannels.isEmpty else {
            pendingChannels.append(channel)
            lock.unlock()
            return
        }
        lock.unlock()
        handler(channel)
    }

    private func flushPendingChannels() {
        lock.lock()
        if drainingChannels { lock.unlock(); return }
        drainingChannels = true
        while let next = pendingChannels.first, let handler = onDataChannel {
            pendingChannels.removeFirst()
            lock.unlock()
            handler(next)
            lock.lock()
        }
        drainingChannels = false
        lock.unlock()
    }

    private func didClose() {
        lock.lock()
        closedEarly = true
        let handler = onClosed
        if handler != nil { closeDelivered = true }
        lock.unlock()
        handler?()
    }

    private func replayCloseIfNeeded() {
        lock.lock()
        guard closedEarly, !closeDelivered, let handler = onClosed else { lock.unlock(); return }
        closeDelivered = true
        lock.unlock()
        handler()
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

/// One data channel: text and binary out, text and binary in, closure on close.
///
/// Same rule as the connection: handlers may arrive after the event. An open
/// that fired before onOpen was set fires once when it is set, and frames
/// that arrived before any message handler existed are queued, in order,
/// and delivered when one is installed. Without this, a caller who builds
/// an 8 KB payload between createDataChannel and onOpen on a loopback pair
/// loses the open and never sends.
public final class DataChannel {
    /// A frame off the wire. Binary frames carry their bytes verbatim,
    /// NULs included - anything that only handles String loses them.
    public enum Message: Sendable {
        case text(String)
        case binary(Data)
    }

    let id: Int32
    private var retained: Unmanaged<DataChannel>?
    private let lock = NSLock()
    private var opened = false
    private var openDelivered = false
    private var closedEarly = false
    private var closeDelivered = false
    private var pending = [Message]()
    private var draining = false

    public var onOpen: (@Sendable () -> Void)? {
        didSet { replayOpenIfNeeded() }
    }
    public var onText: (@Sendable (String) -> Void)? {
        didSet { flushPending() }
    }
    /// Every frame, text and binary alike; onText still fires for text, so
    /// a text-only consumer does not have to switch to this.
    public var onMessage: (@Sendable (Message) -> Void)? {
        didSet { flushPending() }
    }
    public var onClosed: (@Sendable () -> Void)? {
        didSet { replayCloseIfNeeded() }
    }

    init(adopting id: Int32) {
        self.id = id
        retained = Unmanaged.passRetained(self)
        rtcSetUserPointer(id, retained!.toOpaque())
        rtcSetOpenCallback(id) { _, pointer in
            guard let pointer else { return }
            Unmanaged<DataChannel>.fromOpaque(pointer).takeUnretainedValue().didOpen()
        }
        rtcSetMessageCallback(id) { _, message, size, pointer in
            guard let pointer else { return }
            let channel = Unmanaged<DataChannel>.fromOpaque(pointer).takeUnretainedValue()
            if size < 0 {
                // Negative size is this API's way of saying null-terminated text.
                guard let message else { return }
                channel.receive(.text(String(cString: message)))
            } else {
                channel.receive(.binary(size > 0 ? Data(bytes: message!, count: Int(size)) : Data()))
            }
        }
        rtcSetClosedCallback(id) { _, pointer in
            guard let pointer else { return }
            Unmanaged<DataChannel>.fromOpaque(pointer).takeUnretainedValue().didClose()
        }
    }

    private func didOpen() {
        lock.lock()
        opened = true
        let handler = onOpen
        if handler != nil { openDelivered = true }
        lock.unlock()
        handler?()
    }

    private func replayOpenIfNeeded() {
        lock.lock()
        guard opened, !openDelivered, let handler = onOpen else { lock.unlock(); return }
        openDelivered = true
        lock.unlock()
        handler()
    }

    private func didClose() {
        lock.lock()
        closedEarly = true
        let handler = onClosed
        if handler != nil { closeDelivered = true }
        lock.unlock()
        handler?()
    }

    private func replayCloseIfNeeded() {
        lock.lock()
        guard closedEarly, !closeDelivered, let handler = onClosed else { lock.unlock(); return }
        closeDelivered = true
        lock.unlock()
        handler()
    }

    /// Deliver now if a handler exists and nothing is queued ahead of this
    /// frame; otherwise queue, so order survives a late handler.
    private func receive(_ message: Message) {
        lock.lock()
        let handled = onText != nil || onMessage != nil
        if !handled || draining || !pending.isEmpty {
            pending.append(message)
            lock.unlock()
            return
        }
        let (text, any) = (onText, onMessage)
        lock.unlock()
        dispatch(message, text: text, any: any)
    }

    private func flushPending() {
        lock.lock()
        if draining { lock.unlock(); return }
        draining = true
        while let next = pending.first, onText != nil || onMessage != nil {
            pending.removeFirst()
            let (text, any) = (onText, onMessage)
            lock.unlock()
            dispatch(next, text: text, any: any)
            lock.lock()
        }
        draining = false
        lock.unlock()
    }

    private func dispatch(_ message: Message,
                          text: (@Sendable (String) -> Void)?,
                          any: (@Sendable (Message) -> Void)?) {
        if case .text(let string) = message { text?(string) }
        any?(message)
    }

    /// The largest frame this channel will carry, negotiated with the remote
    /// at connection time (libdatachannel's default is 256 KiB). A send of
    /// anything larger is refused synchronously; a caller moving more than
    /// this chunks to it.
    public var maxMessageSize: Int {
        Int(max(rtcMaxMessageSize(id), 0))
    }

    /// Send text; false when the channel is not open or the frame exceeds
    /// maxMessageSize.
    @discardableResult
    public func send(_ text: String) -> Bool {
        rtcSendMessage(id, text, -1) >= 0
    }

    /// Send binary; false when the channel is not open or the frame exceeds
    /// maxMessageSize. A non-negative size is what tells the C API - and the
    /// receiving side - this is bytes, not a null-terminated string.
    @discardableResult
    public func send(_ data: Data) -> Bool {
        guard !data.isEmpty else { return rtcSendMessage(id, nil, 0) >= 0 }
        return data.withUnsafeBytes { buffer in
            rtcSendMessage(id, buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                           Int32(buffer.count)) >= 0
        }
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
