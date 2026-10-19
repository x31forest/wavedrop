import Foundation
import Accelerate

/// Everything the visuals need to know about the music right now.
struct AudioFeatures {
    // MilkDrop-style relative band levels (~1.0 = recent average) and their smoothed versions.
    var bass: Float = 0, mid: Float = 0, treb: Float = 0
    var bassAtt: Float = 0, midAtt: Float = 0, trebAtt: Float = 0
    /// Auto-gained loudness 0…1 (tracks dynamics: pianissimo ≈ low, fortissimo ≈ high).
    var loudness: Float = 0
    /// Decaying 0…1 pulses from detected events.
    var kick: Float = 0, hat: Float = 0, onset: Float = 0
    /// Predicted beat clock (phase-locked to the music).
    var beatPulse: Float = 0
    var beatPhase: Float = 0
    var beatCount: Int = 0
    var bpm: Float = 0
    /// How clearly periodic the music is: 0 = free-flowing (classical), 1 = steady pulse (electronic).
    var rhythm: Float = 0
    /// Spectral brightness 0…1.
    var centroid: Float = 0.5
    /// Hue derived from the dominant pitch classes on the circle of fifths (related keys → related colors).
    var keyHue: Float = 0
    var silent = true
    // One-frame events.
    var beatEvent = false
    var dropEvent = false
    var sectionEvent = false

    static let waveCount = 512
    static let specCount = 64
    var wave = [Float](repeating: 0, count: waveCount)
    var spectrum = [Float](repeating: 0, count: specCount)
}

final class AudioAnalyzer {
    let sampleRate: Float
    private let fftSize = 2048
    private let hop = 512
    private let log2n: vDSP_Length = 11
    private let fftSetup: FFTSetup
    private let hann: [Float]
    private var window: [Float]
    private var pending: [Float] = []
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var logMag: [Float]
    private var prevLogMag: [Float]

    private let frameRate: Float
    private var t: Double = 0        // analysis clock (seconds of audio processed)

    // Band smoothing state.
    private var bandAvg: [Float] = [1e-6, 1e-6, 1e-6]
    private var bandAtt: [Float] = [0, 0, 0]
    private var bandRel: [Float] = [0, 0, 0]

    // Loudness AGC.
    private var dbRef: Float = -30
    private var loudSmooth: Float = 0
    private var loudShort: Float = 0
    private var loudLong: Float = 0
    private var lastSection: Double = 0

    // Onset detectors.
    private var kickDet = PeakDetector(refractory: 0.12, k: 1.4)
    private var hatDet = PeakDetector(refractory: 0.07, k: 1.6)
    private var onsetDet = PeakDetector(refractory: 0.09, k: 1.5)
    private var kickTime: Double = -10, hatTime: Double = -10, onsetTime: Double = -10
    private var kickStrength: Float = 0, hatStrength: Float = 0, onsetStrength: Float = 0

    // Tempo tracking.
    private let envLen: Int
    private var env: [Float]
    private var envLow: [Float]
    private var envCount = 0
    private var framesSinceTempo = 0
    private var bpm: Float = 0
    private var candidateBPM: Float = 0
    private var mismatch = 0
    private var rhythm: Float = 0
    private var rhythmTarget: Float = 0
    private var phase: Double = 0          // in beats
    private var lastBeatIndex = 0
    private var lastBeatTime: Double = -10
    private var beatCount = 0
    private var pendingBeat = false
    /// Visual lookahead to compensate for analysis window + display latency.
    var latencyCompensation: Double = 0.035
    private(set) var debugClarity: Float = 0
    private(set) var debugPeaky: Float = 0

    // Drop / section detection.
    private var bassShort: Float = 0, bassLong: Float = 0, preBreakBass: Float = 0
    private var breakdownTime: Double = 0
    private var inBreakdown = false
    private var pendingDrop = false
    private var pendingSection = false

    // Pitch / brightness.
    private var chroma = [Float](repeating: 0, count: 12)
    private var binPitchClass: [Int]
    private var centroid: Float = 0.5
    private var keyHue: Float = 0

    // Display data.
    private var specSmooth = [Float](repeating: 0, count: AudioFeatures.specCount)
    private var specRanges: [(Int, Int)] = []
    private var specRef: Float = -20
    private var wavePeak: Float = 0.05
    private var rms: Float = 0

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        window = [Float](repeating: 0, count: fftSize)
        windowed = window
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = real
        power = real
        logMag = real
        prevLogMag = real
        frameRate = Float(sampleRate) / Float(hop)
        envLen = Int(frameRate * 8)
        env = [Float](repeating: 0, count: envLen)
        envLow = env

        let binHz = Float(sampleRate) / Float(fftSize)
        binPitchClass = (0..<fftSize / 2).map { k in
            let f = Float(k) * binHz
            guard f >= 65, f <= 2100 else { return -1 }
            let midi = 69 + 12 * log2(f / 440)
            return ((Int(midi.rounded()) % 12) + 12) % 12
        }
        // Log-spaced display bands 30 Hz … 16 kHz.
        let n = AudioFeatures.specCount
        for i in 0..<n {
            let f0 = 30 * pow(16000 / 30, Float(i) / Float(n))
            let f1 = 30 * pow(16000 / 30, Float(i + 1) / Float(n))
            let k0 = max(1, Int(f0 / binHz))
            let k1 = max(k0 + 1, Int(f1 / binHz))
            specRanges.append((k0, min(k1, fftSize / 2)))
        }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Feed newly captured samples; returns the features for the current render frame.
    func process(_ samples: [Float], into f: inout AudioFeatures) {
        pending.append(contentsOf: samples)
        // If we fell far behind (e.g. app was hidden), skip ahead.
        if pending.count > hop * 64 { pending.removeFirst(pending.count - hop * 8) }
        while pending.count >= hop {
            window.removeFirst(hop)
            window.append(contentsOf: pending[0..<hop])
            pending.removeFirst(hop)
            analyzeHop()
        }
        fill(&f)
    }

    // MARK: - Per-hop analysis

    private func analyzeHop() {
        let hopDur = Double(hop) / Double(sampleRate)
        t += hopDur

        // FFT
        vDSP.multiply(window, hann, result: &windowed)
        windowed.withUnsafeBufferPointer { wp in
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    power.withUnsafeMutableBufferPointer { pp in
                        vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(fftSize / 2))
                    }
                }
            }
        }
        power[0] = 0
        let norm = 1 / Float(fftSize * fftSize)
        vDSP.multiply(norm, power, result: &power)

        rms = sqrt(vDSP.meanSquare(window))
        let binHz = sampleRate / Float(fftSize)
        func bin(_ hz: Float) -> Int { min(fftSize / 2 - 1, max(1, Int(hz / binHz))) }

        // Bands (MilkDrop-like relative levels).
        let edges = [(bin(20), bin(160)), (bin(160), bin(2500)), (bin(2500), bin(11000))]
        let silent = rms < 3e-4
        for b in 0..<3 {
            var e: Float = 0
            for k in edges[b].0..<edges[b].1 { e += power[k] }
            let avgRate: Float = 1 - exp(-1 / (frameRate * 4))
            if !silent { bandAvg[b] += (e - bandAvg[b]) * avgRate }
            let rel = silent ? 0 : min(4, e / max(bandAvg[b], 1e-9))
            bandRel[b] = rel
            let attRate: Float = 1 - exp(-1 / (frameRate * 0.12))
            bandAtt[b] += (rel - bandAtt[b]) * attRate
        }

        // Loudness with slow AGC so quiet passages still move.
        let db = 20 * log10(max(rms, 1e-7))
        if db > dbRef { dbRef += (db - dbRef) * 0.05 } else { dbRef -= 0.4 / frameRate }   // ~0.4 dB/s release
        dbRef = max(dbRef, -45)
        let loud = silent ? 0 : min(1, max(0, (db - (dbRef - 36)) / 36))
        loudSmooth += (loud - loudSmooth) * 0.15
        loudShort += (loud - loudShort) * (1 - exp(-1 / (frameRate * 3)))
        loudLong += (loud - loudLong) * (1 - exp(-1 / (frameRate * 20)))
        if abs(loudShort - loudLong) > 0.22, t - lastSection > 20 {
            pendingSection = true
            lastSection = t
        }

        // Spectral flux on compressed magnitudes.
        for k in 0..<fftSize / 2 { logMag[k] = log1p(sqrt(power[k]) * 2000) }
        var fluxLow: Float = 0, fluxFull: Float = 0, fluxHigh: Float = 0
        let kLow = bin(180), kFull = bin(8000), kHigh0 = bin(5000), kHigh1 = bin(16000)
        for k in 1..<kHigh1 {
            let d = max(0, logMag[k] - prevLogMag[k])
            if k < kLow { fluxLow += d }
            if k < kFull { fluxFull += d }
            if k >= kHigh0 { fluxHigh += d }
        }
        fluxLow /= Float(kLow - 1)
        fluxFull /= Float(kFull - 1)
        fluxHigh /= Float(kHigh1 - kHigh0)
        swap(&logMag, &prevLogMag)

        if !silent {
            if let s = kickDet.feed(fluxLow, time: t) { kickTime = t; kickStrength = s }
            if let s = hatDet.feed(fluxHigh, time: t) { hatTime = t; hatStrength = s }
            if let s = onsetDet.feed(fluxFull, time: t) { onsetTime = t; onsetStrength = s }
        }

        // Onset envelope for tempo.
        env.removeFirst()
        env.append(silent ? 0 : 0.5 * fluxFull + 0.5 * fluxLow)
        envLow.removeFirst()
        envLow.append(silent ? 0 : fluxLow)
        envCount += 1
        framesSinceTempo += 1
        if framesSinceTempo >= Int(frameRate / 4), envCount > Int(frameRate * 3) {
            framesSinceTempo = 0
            estimateTempo()
        }
        if silent { rhythmTarget = 0 }
        rhythm += (rhythmTarget - rhythm) * (1 - exp(-1 / (frameRate * 2.5)))

        // Beat clock.
        if bpm > 0 {
            phase += hopDur * Double(bpm) / 60
            let shown = phase + latencyCompensation * Double(bpm) / 60
            let idx = Int(floor(shown))
            if idx > lastBeatIndex {
                lastBeatIndex = idx
                lastBeatTime = t
                beatCount += 1
                pendingBeat = true
            } else if idx < lastBeatIndex - 1 {
                lastBeatIndex = idx
            }
        }

        // Drops: bass vanishes for a while (breakdown), then slams back.
        let bassE = silent ? 0 : bandAvg[0] * bandRel[0]
        bassShort += (bassE - bassShort) * (1 - exp(-1 / (frameRate * 0.4)))
        bassLong += (bassE - bassLong) * (1 - exp(-1 / (frameRate * 10)))
        if !inBreakdown {
            if bassShort < 0.25 * bassLong {
                if breakdownTime == 0 { breakdownTime = t; preBreakBass = bassLong }
                if t - breakdownTime > 3 { inBreakdown = true }
            } else { breakdownTime = 0 }
        } else if bassShort > 0.7 * preBreakBass, t - kickTime < 0.05 {
            inBreakdown = false
            breakdownTime = 0
            pendingDrop = true
        } else if t - breakdownTime > 90 {
            inBreakdown = false; breakdownTime = 0
        }

        // Brightness and key color.
        var num: Float = 0, den: Float = 0
        var frameChroma = [Float](repeating: 0, count: 12)
        for k in 1..<kHigh1 {
            let m = sqrt(power[k])
            num += Float(k) * binHz * m
            den += m
            let pc = binPitchClass[k]
            if pc >= 0 { frameChroma[pc] += m }
        }
        if !silent, den > 0 {
            let c = min(1, max(0, log2(max(num / den, 100) / 200) / log2(40)))
            centroid += (c - centroid) * 0.03
            let rate = 1 - exp(-1 / (frameRate * 3))
            for i in 0..<12 { chroma[i] += (frameChroma[i] - chroma[i]) * rate }
            var x: Float = 0, y: Float = 0
            for pc in 0..<12 {
                let a = 2 * Float.pi * Float((pc * 7) % 12) / 12
                x += chroma[pc] * cos(a); y += chroma[pc] * sin(a)
            }
            if x * x + y * y > 1e-12 {
                let target = atan2(y, x) / (2 * .pi)
                var d = target - keyHue
                d -= d.rounded()
                keyHue += d * 0.01
                keyHue -= floor(keyHue)
            }
        }

        // Display spectrum.
        var frameMax: Float = -120
        for (i, r) in specRanges.enumerated() {
            var e: Float = 0
            for k in r.0..<r.1 { e += power[k] }
            let dbv = 10 * log10(max(e / Float(r.1 - r.0), 1e-14)) + 3 * log2(Float(i + 4))   // tilt: lift highs
            frameMax = max(frameMax, dbv)
            let v = max(0, min(1, (dbv - (specRef - 50)) / 50))
            specSmooth[i] = v > specSmooth[i] ? v : specSmooth[i] * 0.9 + v * 0.1
        }
        if !silent {
            if frameMax > specRef { specRef = frameMax } else { specRef -= 3 / frameRate }
        }
    }

    // MARK: - Tempo

    /// Local-mean detrend, half-wave rectify, then a light blur so fractional beat periods
    /// don't split their energy across integer lags.
    private func detrend(_ x: [Float]) -> [Float] {
        let n = x.count
        var cs = [Float](repeating: 0, count: n + 1)
        for i in 0..<n { cs[i + 1] = cs[i] + x[i] }
        let w = 8
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - w), b = min(n, i + w + 1)
            raw[i] = max(0, x[i] - (cs[b] - cs[a]) / Float(b - a))
        }
        var e = [Float](repeating: 0, count: n)
        let kern: [Float] = [1, 2, 3, 2, 1]
        for i in 0..<n {
            var s: Float = 0, ws: Float = 0
            for j in 0..<5 where i + j - 2 >= 0 && i + j - 2 < n { s += raw[i + j - 2] * kern[j]; ws += kern[j] }
            e[i] = s / ws
        }
        return e
    }

    private func estimateTempo() {
        let n = envLen
        let eAll = detrend(env)
        let eLow = detrend(envLow)
        // Tempo from a low-weighted mix: kicks define the pulse, hats/off-beats only support it.
        let maxLow = max(eLow.max() ?? 0, 1e-9), maxAll = max(eAll.max() ?? 0, 1e-9)
        var e = [Float](repeating: 0, count: n)
        for i in 0..<n { e[i] = eLow[i] / maxLow + 0.5 * eAll[i] / maxAll }
        let ac0 = e.reduce(0) { $0 + $1 * $1 }
        guard ac0 > 1e-9 else { rhythmTarget = 0; return }

        let lMin = Int(frameRate * 60 / 190), lMax = Int(frameRate * 60 / 65)
        var ac = [Float](repeating: 0, count: 2 * lMax + 2)
        e.withUnsafeBufferPointer { ep in
            for l in lMin...(2 * lMax + 1) where l < n {
                var s: Float = 0
                vDSP_dotpr(ep.baseAddress! + l, 1, ep.baseAddress!, 1, &s, vDSP_Length(n - l))
                ac[l] = s / (ac0 * Float(n - l) / Float(n))
            }
        }
        var best = lMin, bestScore: Float = -1, mean: Float = 0
        for l in lMin...lMax {
            let b = 60 * frameRate / Float(l)
            let pref = exp(-0.5 * pow(log2(b / 125) / 1.0, 2))
            let score = (ac[l] + 0.5 * ac[2 * l]) * pref
            mean += ac[l]
            if score > bestScore { bestScore = score; best = l }
        }
        mean /= Float(lMax - lMin + 1)
        // Parabolic refinement.
        var lag = Float(best)
        if best > lMin, best < lMax {
            let y0 = ac[best - 1], y1 = ac[best], y2 = ac[best + 1]
            let d = y0 - 2 * y1 + y2
            if abs(d) > 1e-9 { lag += max(-0.5, min(0.5, 0.5 * (y0 - y2) / d)) }
        }
        let clarity = ac[best] - mean
        // Percussiveness: how spiky the onset envelope is relative to its level (kicks ≫ bowed strings).
        let envMean = env.reduce(0, +) / Float(n)
        let peaky = sqrt(eAll.reduce(0) { $0 + $1 * $1 } / Float(n)) / max(envMean, 1e-6)
        debugClarity = clarity; debugPeaky = peaky
        rhythmTarget = min(1, max(0, (clarity - 0.06) / 0.22)) * min(1, max(0, (peaky - 0.15) / 0.25))

        let cand = 60 * frameRate / lag
        // Free-flowing music: keep the last tempo but don't chase noise.
        guard rhythmTarget > 0.15 else { return }
        if bpm == 0 {
            if rhythmTarget > 0.15 { bpm = cand }
        } else {
            let ratio = cand / bpm
            if abs(ratio - 1) < 0.04 {
                bpm += (cand - bpm) * 0.25
                mismatch = 0
            } else if abs(ratio - 2) < 0.08 || abs(ratio - 0.5) < 0.04 {
                // Octave ambiguity: stick with what we have unless it persists.
                mismatch += 1
                if mismatch > 12 { bpm = cand; mismatch = 0 }
            } else {
                if abs(cand / max(candidateBPM, 1) - 1) < 0.04 { mismatch += 1 } else { mismatch = 1 }
                candidateBPM = cand
                if mismatch >= 4 { bpm = cand; mismatch = 0 }
            }
        }
        guard bpm > 0, rhythmTarget > 0.1 else { return }

        // Phase: find the offset whose comb of beat positions catches the most onset energy.
        // Beats land on the low end (kicks, bass, timpani), so weight the low-band envelope heavily —
        // otherwise off-beat hi-hats can steal the phase.
        var ep = [Float](repeating: 0, count: n)
        for i in 0..<n { ep[i] = eLow[i] / maxLow + 0.3 * eAll[i] / maxAll }

        let period = 60 * frameRate / bpm
        let clockFrac = phase - floor(phase)
        let p = Int(period)
        var bestOff = 0, bestSum: Float = -1
        for off in 0..<max(p, 1) {
            var s: Float = 0
            var k = 0
            while true {
                let idx = n - 1 - off - Int((Float(k) * period).rounded())
                if idx < 0 || k > 12 { break }
                s += ep[idx] * (1 - Float(k) * 0.05)
                k += 1
            }
            // Mild preference for staying where the clock already is (stability).
            s *= 1 + 0.15 * Float(cos(2 * .pi * (Double(off) / Double(period) - clockFrac)))
            if s > bestSum { bestSum = s; bestOff = off }
        }
        // bestOff frames have elapsed since the most recent beat (at analysis time).
        let target = Double(bestOff) / Double(period)
        var err = target - clockFrac
        err -= err.rounded()
        if ProcessInfo.processInfo.environment["WD_DEBUG"] != nil {
            print(String(format: "t %.2f bpm %.2f cand %.2f off %d period %.2f target %.3f frac %.3f err %+.3f",
                         t, bpm, cand, bestOff, period, target, clockFrac, err))
        }
        phase += err * 0.3
    }

    // MARK: - Output

    private func fill(_ f: inout AudioFeatures) {
        f.bass = bandRel[0]; f.mid = bandRel[1]; f.treb = bandRel[2]
        f.bassAtt = bandAtt[0]; f.midAtt = bandAtt[1]; f.trebAtt = bandAtt[2]
        f.loudness = loudSmooth
        func pulse(_ since: Double, _ tau: Double, _ s: Float) -> Float { since < 0 ? 0 : s * Float(exp(-since / tau)) }
        f.kick = pulse(t - kickTime, 0.12, kickStrength)
        f.hat = pulse(t - hatTime, 0.06, hatStrength)
        f.onset = pulse(t - onsetTime, 0.25, onsetStrength)
        f.bpm = bpm
        f.rhythm = rhythm
        let period = bpm > 0 ? 60 / Double(bpm) : 0.5
        f.beatPulse = bpm > 0 ? Float(exp(-(t - lastBeatTime) / (period * 0.3))) : 0
        let shown = phase + latencyCompensation * Double(bpm) / 60
        f.beatPhase = Float(shown - floor(shown))
        f.beatCount = beatCount
        f.centroid = centroid
        f.keyHue = keyHue
        f.silent = rms < 3e-4
        f.beatEvent = pendingBeat; pendingBeat = false
        f.dropEvent = pendingDrop; pendingDrop = false
        f.sectionEvent = pendingSection; pendingSection = false
        f.spectrum = specSmooth

        // Waveform: trigger on a rising zero crossing so it doesn't jitter, auto-gained.
        let count = AudioFeatures.waveCount
        var peak: Float = 0
        for v in window { peak = max(peak, abs(v)) }
        wavePeak = max(peak, wavePeak * 0.995, 0.02)
        let gain = 0.9 / wavePeak
        var start = fftSize - count
        var i = fftSize - count - 1
        while i > fftSize - count - 512, i > 0 {
            if window[i - 1] < 0, window[i] >= 0 { start = i; break }
            i -= 1
        }
        for j in 0..<count { f.wave[j] = window[min(fftSize - 1, start + j)] * gain }
    }
}

/// Adaptive-threshold onset picker: fires on rising crossings of mean + k·σ over the last ~0.6 s.
struct PeakDetector {
    let refractory: Double
    let k: Float
    private var hist = [Float](repeating: 0, count: 56)
    private var idx = 0
    private var last: Double = -10
    private var prev: Float = 0

    init(refractory: Double, k: Float) { self.refractory = refractory; self.k = k }

    mutating func feed(_ x: Float, time: Double) -> Float? {
        var mean: Float = 0, sq: Float = 0
        for v in hist { mean += v; sq += v * v }
        mean /= Float(hist.count)
        let sd = sqrt(max(0, sq / Float(hist.count) - mean * mean))
        let thr = mean + k * sd + 0.02
        hist[idx] = x; idx = (idx + 1) % hist.count
        defer { prev = x }
        if x > thr, prev <= x, time - last > refractory {
            last = time
            return min(1, 0.45 + 0.55 * (x - thr) / max(thr, 1e-6))
        }
        return nil
    }
}
