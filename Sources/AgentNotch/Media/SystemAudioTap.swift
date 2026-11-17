import CoreAudio
import Foundation

enum AudioTapError: LocalizedError {
    case status(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let step, let code): "\(step) failed (OSStatus \(code))"
        }
    }
}

/// Captures the Mac's mixed audio output with a Core Audio process tap (macOS 14.2+) and feeds it
/// to a SpectrumAnalyzer. Audio is analyzed in memory as it arrives; nothing is recorded or stored.
///
/// Requires the "System Audio Recording" privacy permission; macOS asks the first time a tap starts.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    /// Called on the main queue, at most ~30 times per second.
    var onLevels: (@MainActor ([Float]) -> Void)?

    private let queue = DispatchQueue(label: "dev.agentnotch.audiotap", qos: .userInteractive)
    private let analyzer = SpectrumAnalyzer(bandCount: 4)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var lastPublish: CFAbsoluteTime = 0
    private var mono: [Float] = []

    private(set) var isRunning = false

    func start() throws {
        guard !isRunning else { return }
        do {
            try createTapAndDevice()
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
        queue.async { [analyzer] in analyzer.reset() }
    }

    deinit { stop() }

    // MARK: - Setup

    private func createTapAndDevice() throws {
        // Stereo mixdown of everything the Mac plays. Unmuted: listening doesn't change what you hear.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "AgentNotch Visualizer"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creating audio tap")
        tapID = tap

        // A tap is read through a private aggregate device clocked by the current output device.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AgentNotch Visualizer",
            kAudioAggregateDeviceUIDKey: "dev.agentnotch.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Creating aggregate device")
        aggregateID = device

        let format = try Self.streamFormat(of: tap)
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        guard isFloat else { throw AudioTapError.status("Unsupported tap format", -1) }
        let sampleRate = Float(format.mSampleRate)
        queue.async { [analyzer] in analyzer.sampleRate = sampleRate }

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            self?.process(input, channels: channels, interleaved: interleaved)
        }, "Creating IO proc")
        procID = proc
        try check(AudioDeviceStart(device, proc), "Starting audio device")
    }

    // MARK: - Processing (on `queue`)

    private func process(_ input: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let firstData = first.mData else { return }

        // Mix down to mono.
        if interleaved {
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = firstData.assumingMemoryBound(to: Float.self)
            if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[f * channels + c] }
                mono[f] = sum / Float(channels)
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
            for i in 0..<frames { mono[i] = 0 }
            var used = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) { mono[i] += samples[i] }
                used += 1
            }
            if used > 1 { for i in 0..<frames { mono[i] /= Float(used) } }
        }

        guard let levels = mono.withUnsafeBufferPointer({ analyzer.append($0) }) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPublish >= 1.0 / 30.0 else { return }
        lastPublish = now
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onLevels?(levels) }
        }
    }

    // MARK: - Helpers

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioTapError.status(step, status) }
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw AudioTapError.status("Finding output device", status)
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw AudioTapError.status("Reading output device UID", status) }
        return uid.takeRetainedValue() as String
    }

    private static func streamFormat(of tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr else { throw AudioTapError.status("Reading tap format", status) }
        return format
    }
}
