import Foundation
import CoreAudio
import AudioToolbox
import os

/// Single-producer / single-consumer mono sample ring, shared between the audio thread and the render loop.
final class SampleRing {
    private var buffer: [Float]
    private let mask: Int
    private var writeIndex = 0   // total samples ever written
    private var readIndex = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacityPow2: Int = 1 << 17) {
        buffer = [Float](repeating: 0, count: capacityPow2)
        mask = capacityPow2 - 1
    }

    func write(_ ptr: UnsafePointer<Float>, count: Int, stride: Int = 1, mixWith second: UnsafePointer<Float>? = nil, secondStride: Int = 1) {
        lock.lock()
        buffer.withUnsafeMutableBufferPointer { buf in
            var w = writeIndex
            if let second {
                for i in 0..<count {
                    buf[w & mask] = 0.5 * (ptr[i * stride] + second[i * secondStride])
                    w += 1
                }
            } else {
                for i in 0..<count {
                    buf[w & mask] = ptr[i * stride]
                    w += 1
                }
            }
            writeIndex = w
        }
        lock.unlock()
    }

    /// Returns all samples written since the last call (bounded by capacity).
    func readNew(into out: inout [Float]) {
        lock.lock()
        let available = min(writeIndex - readIndex, mask + 1)
        let start = writeIndex - available
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(available)
        for i in 0..<available { out.append(buffer[(start + i) & mask]) }
        readIndex = writeIndex
        lock.unlock()
    }
}

protocol AudioSource: AnyObject {
    var sampleRate: Double { get }
    var ring: SampleRing { get }
    var statusText: String { get }
    func start() throws
    func stop()
}

enum CaptureError: LocalizedError {
    case osStatus(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case let .osStatus(what, s): return "\(what) failed (OSStatus \(s))"
        }
    }
}

private func check(_ s: OSStatus, _ what: String) throws {
    if s != noErr { throw CaptureError.osStatus(what, s) }
}

/// Captures everything the Mac is playing using a Core Audio process tap (macOS 14.2+).
/// Requires the "System Audio Recording" privacy permission (prompted on first start).
final class SystemAudioTap: AudioSource {
    let ring = SampleRing()
    private(set) var sampleRate: Double = 48_000
    private(set) var statusText = "Starting system audio tap…"

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "wavedrop.audio", qos: .userInteractive)

    func start() throws {
        // Global stereo tap of all processes, excluding ourselves.
        var excluded: [AudioObjectID] = []
        if let me = Self.processObject(for: getpid()) { excluded.append(me) }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.name = "Wavedrop Tap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        try check(AudioHardwareCreateProcessTap(desc, &tapID), "Create process tap")

        // Tap stream format.
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt), "Read tap format")
        sampleRate = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48_000

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Wavedrop Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID), "Create aggregate device")

        let ring = self.ring
        let interleaved = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let channels = Int(max(fmt.mChannelsPerFrame, 1))
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard abl.count > 0, let d0 = abl[0].mData else { return }
            let p0 = d0.assumingMemoryBound(to: Float.self)
            if interleaved || abl.count == 1 {
                let ch = Int(max(abl[0].mNumberChannels, 1))
                let frames = Int(abl[0].mDataByteSize) / (4 * ch)
                if ch >= 2 {
                    ring.write(p0, count: frames, stride: ch, mixWith: p0 + 1, secondStride: ch)
                } else {
                    ring.write(p0, count: frames)
                }
            } else {
                let frames = Int(abl[0].mDataByteSize) / 4
                if abl.count >= 2, let d1 = abl[1].mData {
                    ring.write(p0, count: frames, mixWith: d1.assumingMemoryBound(to: Float.self))
                } else {
                    ring.write(p0, count: frames)
                }
            }
            _ = channels
        }, "Create IO proc")

        try check(AudioDeviceStart(aggregateID, procID), "Start audio device")
        statusText = "Listening to system audio (\(Int(sampleRate)) Hz)"
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                           UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return (s == noErr && obj != kAudioObjectUnknown) ? obj : nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev), "Find output device")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid), "Read output device UID")
        return (uid?.takeRetainedValue() as String?) ?? ""
    }

    deinit { stop() }
}

/// Synthetic music for trying the app without capture permission (`--demo`).
/// Alternates a 126 BPM four-on-the-floor section with a slow, swelling string-like section.
final class DemoSource: AudioSource {
    let ring = SampleRing()
    let sampleRate: Double = 48_000
    var statusText: String { "Demo signal (run without --demo to visualize system audio)" }
    private var timer: DispatchSourceTimer?
    private var n = 0

    func start() throws {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "wavedrop.demo"))
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        var chunk = [Float](repeating: 0, count: 480)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for i in 0..<480 { chunk[i] = DemoSource.sample(self.n + i, sr: self.sampleRate) }
            self.n += 480
            chunk.withUnsafeBufferPointer { self.ring.write($0.baseAddress!, count: 480) }
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    /// 32 s electronic, 32 s "classical", repeating.
    static func sample(_ n: Int, sr: Double) -> Float {
        let t = Double(n) / sr
        let section = Int(t / 32) % 2
        if section == 0 { return electronic(t) } else { return strings(t) }
    }

    static func electronic(_ t: Double, bpm: Double = 126) -> Float {
        let beat = 60 / bpm
        let tb = t.truncatingRemainder(dividingBy: beat)
        let kick = sin(2 * .pi * (50 * tb + 120 * (1 - exp(-tb * 30)) / 30)) * exp(-tb * 9)
        let th = (t + beat / 2).truncatingRemainder(dividingBy: beat)
        let hat = Double.random(in: -1...1) * exp(-th * 60) * 0.25
        let bass = sin(2 * .pi * 55 * t) * 0.25 * (1 - exp(-th * 20))
        return Float(0.7 * kick + hat + bass)
    }

    /// Slow string-like chords (A – D – E – F#m), each voice with its own vibrato rate, swelling dynamics.
    static func strings(_ t: Double) -> Float {
        let swell = 0.5 - 0.5 * cos(2 * .pi * t / 11)
        let chords: [[Double]] = [[220, 277.18, 329.63, 440], [293.66, 369.99, 440, 587.33],
                                  [329.63, 415.3, 493.88, 659.26], [369.99, 440, 554.37, 739.99]]
        let pos = t / 4.7
        let ci = Int(pos) % chords.count
        let fadeIn = min(1, (pos - floor(pos)) * 4.7 / 0.8)   // soft bowing attack
        let vibRates = [5.1, 5.7, 6.3, 4.8]
        var s = 0.0
        for (i, f) in chords[ci].enumerated() {
            let ph = 2 * .pi * f * t + 0.004 * f / vibRates[i] * sin(2 * .pi * vibRates[i] * t + Double(i))
            s += (sin(ph) + 0.3 * sin(2 * ph) + 0.15 * sin(3 * ph)) * 0.1
        }
        return Float(s * (0.15 + 0.85 * swell) * fadeIn)
    }
}
