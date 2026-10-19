import Foundation
import AVFoundation

/// Developer tools for tuning the beat tracker on real music:
///   `--record <seconds> <out.wav>`  captures system audio to a mono WAV (run via `open … --args` so
///                                   the app's own audio permission applies)
///   `--analyze <file>`              runs the analyzer over an audio file and reports tempo, beat
///                                   alignment against detected kicks, and bar position over time
enum RecordAnalyze {
    static func record(seconds: Double, path: String) {
        let tap = SystemAudioTap()
        do { try tap.start() } catch {
            debugLog("record failed: \(error.localizedDescription)")
            exit(1)
        }
        var all: [Float] = []
        var chunk: [Float] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            tap.ring.readNew(into: &chunk)
            all.append(contentsOf: chunk)
        }
        tap.stop()
        do {
            try write(all, sampleRate: tap.sampleRate, to: path)
            debugLog("recorded \(all.count) samples (\(String(format: "%.1f", Double(all.count) / tap.sampleRate)) s) to \(path)")
        } catch {
            debugLog("record write failed: \(error)")
        }
        exit(0)
    }

    static func write(_ samples: [Float], sampleRate: Double, to path: String) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
    }

    static func read(_ path: String) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let fmt = file.processingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let n = Int(buf.frameLength), ch = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<ch {
            let p = buf.floatChannelData![c]
            for i in 0..<n { mono[i] += p[i] / Float(ch) }
        }
        return (mono, fmt.sampleRate)
    }

    static func analyze(path: String) {
        guard let (samples, sr) = try? read(path) else { print("could not read \(path)"); exit(1) }
        let a = AudioAnalyzer(sampleRate: sr)
        a.latencyCompensation = 0   // compare against the audio itself
        var f = AudioFeatures()
        let chunk = Int(sr / 60)
        var beats: [Double] = [], kicks: [Double] = [], downbeats: [Double] = []
        var lastKick: Float = 0
        var nextReport = 5.0
        print(String(format: "%@  (%.1f s @ %.0f Hz)", (path as NSString).lastPathComponent, Double(samples.count) / sr, sr))
        var i = 0
        while i + chunk <= samples.count {
            a.process(Array(samples[i..<i + chunk]), into: &f)
            i += chunk
            let t = Double(i) / sr
            if f.beatEvent { beats.append(t); if f.beatInBar == 0 { downbeats.append(t) } }
            if f.kick > 0.4 && f.kick > lastKick + 0.2 { kicks.append(t) }
            lastKick = f.kick
            if t >= nextReport {
                nextReport += 5
                print(String(format: "  %5.1fs  bpm %6.1f  rhythm %.2f  loud %.2f  bar beat %d  bars %d",
                             t, f.bpm, f.rhythm, f.loudness, f.beatInBar, f.barCount))
            }
        }
        // How well do predicted beats line up with real kicks? (median |offset| to the nearest kick)
        let settled = beats.filter { $0 > 8 }
        var offsets: [Double] = []
        for b in settled {
            if let k = kicks.min(by: { abs($0 - b) < abs($1 - b) }), abs(k - b) < 0.12 { offsets.append(k - b) }
        }
        offsets.sort()
        let ioi = zip(settled.dropFirst(), settled).map { $0 - $1 }
        let mean = ioi.reduce(0, +) / Double(max(ioi.count, 1))
        let sd = sqrt(ioi.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(ioi.count, 1)))
        print(String(format: "  beats %d, kicks %d, beats near a kick %d%%, median kick offset %+.0f ms, beat interval %.3f s ± %.0f ms",
                     settled.count, kicks.count, settled.isEmpty ? 0 : 100 * offsets.count / settled.count,
                     offsets.isEmpty ? 0 : offsets[offsets.count / 2] * 1000, mean, sd * 1000))
        exit(0)
    }
}
