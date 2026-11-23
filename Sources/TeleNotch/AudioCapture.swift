import AVFAudio
import CoreAudio
import Foundation

typealias BufferHandler = (AVAudioPCMBuffer) -> Void

enum CaptureError: LocalizedError {
    case osStatus(String, OSStatus)
    case noFormat
    var errorDescription: String? {
        switch self {
        case .osStatus(let what, let s): return "\(what) failed (\(s))"
        case .noFormat: return "Couldn't read the audio format"
        }
    }
}

// MARK: - Audio devices

enum AudioDevices {
    static func defaultInput() -> AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultInputDevice) }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = uint32(id, kAudioDevicePropertyTransportType) ?? 0
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The Mac's own microphone, if it has one.
    static func builtInInput() -> AudioDeviceID? {
        allDevices().first { uint32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return "microphone" }
        return n as String
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func allDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }
}

/// Calls back (on the main queue) when the default mic or speakers change (e.g. headphones connect).
final class AudioDeviceWatcher {
    private let onChange: () -> Void
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        // Not kAudioHardwarePropertyDevices: our own capture device would trigger it, and we'd restart in a loop.
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                    kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
                listeners.append((addr, block))
            }
        }
    }

    deinit {
        for (a, block) in listeners {
            var addr = a
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
    }
}

/// When audio last arrived from a source. Written on audio threads, read on the main thread.
final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date()
    func beat() { lock.lock(); t = Date(); lock.unlock() }
    var last: Date { lock.lock(); defer { lock.unlock() }; return t }
}

// MARK: - Microphone ("Me")

final class MicCapture {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    /// The microphone in use, e.g. "MacBook Air Microphone".
    private(set) var deviceName = ""
    /// True when the default mic was a Bluetooth headset and we used the built-in mic instead.
    private(set) var avoidedBluetooth = false
    /// The engine stopped because the audio hardware changed underneath it.
    var onConfigurationChange: (() -> Void)?

    func start(_ onBuffer: @escaping BufferHandler) throws {
        let e = AVAudioEngine()
        let input = e.inputNode
        // Recording from a Bluetooth headset's mic switches it into low-quality "call mode", which also
        // changes what it plays and breaks the system-audio capture. Use the Mac's own mic instead.
        var device = AudioDevices.defaultInput()
        avoidedBluetooth = false
        if let d = device, AudioDevices.isBluetooth(d), let builtIn = AudioDevices.builtInInput(), let unit = input.audioUnit {
            var id = builtIn
            if AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr {
                device = builtIn
                avoidedBluetooth = true
            }
        }
        deviceName = device.map(AudioDevices.name) ?? "microphone"

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noFormat }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in onBuffer(buffer) }
        e.prepare()
        try e.start()
        engine = e
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

// MARK: - Everything the Mac plays ("Others"), via a Core Audio process tap (macOS 14.4+)

final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "telenotch.systemaudio", qos: .userInitiated)

    func start(_ onBuffer: @escaping BufferHandler) throws {
        // Tap every process's output, mixed to stereo. We play no audio ourselves, so nothing to exclude.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.name = "TeleNotch system audio"
        try check("Creating the audio tap", AudioHardwareCreateProcessTap(desc, &tapID))

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TeleNotch Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                              kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check("Creating the aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check("Reading the tap format", AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd))
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.noFormat }

        try check("Starting the audio callback", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInput, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInput, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            // The tap's memory is only valid during this callback, so hand on a copy.
            if let copy = buffer.deepCopy() { onBuffer(copy) }
        })
        try check("Starting system audio", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private static func defaultOutputUID() throws -> String {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check("Finding the output device", AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device))
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        try check("Reading the output device", AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid))
        guard let s = uid?.takeRetainedValue() else { throw CaptureError.noFormat }
        return s as String
    }
}

private func check(_ what: String, _ status: OSStatus) throws {
    if status != noErr { throw CaptureError.osStatus(what, status) }
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        out.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sp = s.mData, let dp = d.mData else { continue }
            memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return out
    }
}
