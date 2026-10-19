import Foundation

/// `Wavedrop --selftest`: runs the analyzer on synthetic signals and prints what it detects.
enum SelfTest {
    static func run() {
        let sr = 48_000.0
        func analyze(_ name: String, seconds: Double, bpm trueBPM: Double? = nil, _ gen: (Double) -> Float) {
            let a = AudioAnalyzer(sampleRate: sr)
            var f = AudioFeatures()
            let chunk = 800   // ~60 fps
            var n = 0
            var buf = [Float](repeating: 0, count: chunk)
            var beatTimes: [Double] = []
            while Double(n) < seconds * sr {
                for i in 0..<chunk { buf[i] = gen(Double(n + i) / sr) }
                n += chunk
                a.process(buf, into: &f)
                if f.beatEvent { beatTimes.append(Double(n) / sr) }
            }
            print(String(format: "%-28@ bpm %6.1f  rhythm %.2f (clarity %.2f peaky %.2f)  loud %.2f  hue %.2f  bright %.2f  beats %d",
                         name as NSString, f.bpm, f.rhythm, a.debugClarity, a.debugPeaky, f.loudness, f.keyHue, f.centroid, beatTimes.count))
            // Beat alignment vs the true grid over the second half (circular mean / spread, in ms).
            if let trueBPM {
                let period = 60 / trueBPM
                let late = beatTimes.filter { $0 > seconds / 2 }
                guard !late.isEmpty else { return }
                var x = 0.0, y = 0.0
                for bt in late { let a = 2 * .pi * bt / period; x += cos(a); y += sin(a) }
                let r = sqrt(x * x + y * y) / Double(late.count)
                let meanOff = atan2(y, x) / (2 * .pi) * period * 1000
                let spread = sqrt(max(0, -2 * log(max(r, 1e-9)))) / (2 * .pi) * period * 1000
                print(String(format: "    beats in 2nd half %d (expected %.0f), offset %+.0f ms, jitter %.0f ms",
                             late.count, seconds / 2 / period, meanOff, spread))
            }
        }
        analyze("electronic 126", seconds: 24, bpm: 126) { DemoSource.electronic($0, bpm: 126) }
        analyze("electronic 140", seconds: 24, bpm: 140) { DemoSource.electronic($0, bpm: 140) }
        analyze("electronic 174 (dnb)", seconds: 24, bpm: 174) { DemoSource.electronic($0, bpm: 174) }
        analyze("electronic 100", seconds: 24, bpm: 100) { DemoSource.electronic($0, bpm: 100) }
        analyze("strings (slow chords)", seconds: 30) { DemoSource.strings($0) }
        analyze("noise", seconds: 10) { _ in Float.random(in: -0.2...0.2) }
        analyze("silence", seconds: 5) { _ in 0 }
    }
}
