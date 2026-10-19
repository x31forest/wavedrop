import Foundation

/// Per-preset look & motion. Floats only, same order as `struct P` in Shaders.swift.
struct PresetParams {
    var zoom: Float = 1.01, zoomBeat: Float = 0, zoomExp: Float = 1, rot: Float = 0, rotBeat: Float = 0
    var warp: Float = 0, warpScale: Float = 2, warpSpeed: Float = 0.1
    var swirl: Float = 0, dx: Float = 0, dy: Float = 0, decay: Float = 0.96, hueDrift: Float = 0
    var kaleido: Float = 0, mirror: Float = 0, cx: Float = 0, cy: Float = 0
    var waveLine: Float = 0, waveCircle: Float = 0, spectrumRing: Float = 0, spectrumBars: Float = 0
    var sparkles: Float = 0, orbs: Float = 0
    var waveScale: Float = 1, waveThick: Float = 1, hueSpread: Float = 0.2, saturation: Float = 0.8
    var echo: Float = 0, brightness: Float = 1

    static func lerp(_ a: PresetParams, _ b: PresetParams, _ t: Float) -> PresetParams {
        var out = a
        var bb = b
        withUnsafeMutableBytes(of: &out) { o in
            withUnsafeBytes(of: &bb) { bp in
                let of = o.bindMemory(to: Float.self), bf = bp.bindMemory(to: Float.self)
                for i in 0..<of.count { of[i] += (bf[i] - of[i]) * t }
            }
        }
        // Symmetry modes can't be interpolated; flip them halfway through.
        out.kaleido = t < 0.5 ? a.kaleido : b.kaleido
        out.mirror = t < 0.5 ? a.mirror : b.mirror
        return out
    }
}

/// Everything sent to the GPU each frame. Same order as `struct U` in Shaders.swift.
struct Uniforms {
    var time: Float = 0, dt: Float = 1, resX: Float = 1, resY: Float = 1
    var bass: Float = 0, mid: Float = 0, treb: Float = 0, bassAtt: Float = 0, midAtt: Float = 0, trebAtt: Float = 0
    var loudness: Float = 0, kick: Float = 0, hat: Float = 0, onset: Float = 0, beat: Float = 0, beatPhase: Float = 0
    var rhythm: Float = 0, centroid: Float = 0, hue: Float = 0, flash: Float = 0, seed: Float = 0, rotSign: Float = 1
    var p = PresetParams()
}

struct Preset {
    let name: String
    /// 0 = made for free-flowing / classical, 1 = made for a steady electronic pulse.
    let affinity: Float
    let params: PresetParams
}

enum StyleMode: String, CaseIterable {
    case auto = "Auto", electronic = "Electronic", classical = "Classical"
    var next: StyleMode { StyleMode.allCases[(StyleMode.allCases.firstIndex(of: self)! + 1) % 3] }
}

private func make(_ f: (inout PresetParams) -> Void) -> PresetParams { var p = PresetParams(); f(&p); return p }

let presets: [Preset] = [
    // ---- Pulse-driven (electronic) ---------------------------------------
    Preset(name: "Hyperspace Tunnel", affinity: 0.9, params: make {
        $0.zoom = 1.035; $0.zoomBeat = 0.05; $0.zoomExp = 1.3; $0.rot = 0.004; $0.rotBeat = 0.02
        $0.waveCircle = 1; $0.sparkles = 0.6; $0.decay = 0.92; $0.hueDrift = 0.01; $0.waveScale = 1.2
    }),
    Preset(name: "Kick Kaleidoscope", affinity: 0.85, params: make {
        $0.kaleido = 6; $0.zoom = 1.015; $0.zoomBeat = 0.06; $0.rot = 0.01; $0.rotBeat = 0.03
        $0.spectrumRing = 0.55; $0.waveCircle = 0.4; $0.decay = 0.91; $0.hueDrift = 0.02; $0.saturation = 0.9
    }),
    Preset(name: "Laser Mirror", affinity: 0.95, params: make {
        $0.mirror = 1; $0.waveLine = 1; $0.spectrumBars = 0.6; $0.zoom = 1.0; $0.zoomBeat = 0.03
        $0.dy = -0.5; $0.decay = 0.88; $0.echo = 0.6; $0.waveThick = 0.6; $0.saturation = 1; $0.hueSpread = 0.4
    }),
    Preset(name: "Bass Bloom", affinity: 0.8, params: make {
        $0.zoom = 1.02; $0.zoomBeat = 0.08; $0.zoomExp = 0.7; $0.orbs = 0.5; $0.spectrumRing = 0.5
        $0.warp = 0.6; $0.decay = 0.9; $0.hueSpread = 0.3
    }),
    Preset(name: "Acid Swirl", affinity: 0.75, params: make {
        $0.swirl = 0.03; $0.warp = 1.5; $0.warpScale = 3; $0.warpSpeed = 0.4; $0.zoom = 1.01; $0.zoomBeat = 0.04
        $0.waveCircle = 0.7; $0.hueDrift = 0.03; $0.decay = 0.95; $0.rotBeat = 0.04
    }),
    Preset(name: "Strobe Grid", affinity: 0.9, params: make {
        $0.kaleido = 4; $0.mirror = 1; $0.zoom = 1.04; $0.zoomBeat = 0.07; $0.rotBeat = 0.06
        $0.waveLine = 1; $0.decay = 0.85; $0.sparkles = 1; $0.echo = 0.4; $0.saturation = 0.95
    }),
    Preset(name: "Liquid Gold", affinity: 0.55, params: make {
        $0.warp = 1.0; $0.swirl = 0.01; $0.zoom = 1.008; $0.zoomBeat = 0.03; $0.waveCircle = 0.8
        $0.spectrumRing = 0.3; $0.decay = 0.945; $0.brightness = 0.7; $0.hueSpread = 0.1; $0.saturation = 0.75; $0.rotBeat = 0.015
    }),
    // ---- Flowing (classical) ---------------------------------------------
    Preset(name: "Nebula", affinity: 0.15, params: make {
        $0.warp = 1.2; $0.warpScale = 1.5; $0.warpSpeed = 0.05; $0.zoom = 1.004; $0.decay = 0.985
        $0.sparkles = 0.5; $0.orbs = 0.3; $0.waveCircle = 0.3; $0.brightness = 0.7; $0.waveThick = 2; $0.hueDrift = 0.002; $0.saturation = 0.6
    }),
    Preset(name: "Aurora", affinity: 0.1, params: make {
        $0.dy = 0.25; $0.warp = 0.8; $0.warpScale = 1.2; $0.waveLine = 1; $0.waveThick = 2.5; $0.waveScale = 0.7
        $0.decay = 0.975; $0.zoom = 1.0; $0.saturation = 0.7; $0.hueSpread = 0.35
    }),
    Preset(name: "Ink in Water", affinity: 0.2, params: make {
        $0.warp = 2.0; $0.warpScale = 2.5; $0.warpSpeed = 0.03; $0.swirl = 0.004; $0.zoom = 0.998; $0.decay = 0.99
        $0.orbs = 0.45; $0.waveCircle = 0.25; $0.saturation = 0.6; $0.brightness = 0.45
    }),
    Preset(name: "Cathedral", affinity: 0.3, params: make {
        $0.kaleido = 8; $0.rot = 0.0015; $0.zoom = 1.006; $0.decay = 0.98; $0.spectrumRing = 0.5
        $0.waveCircle = 0.5; $0.warp = 0.3; $0.saturation = 0.6; $0.echo = 0.3; $0.zoomBeat = 0.01
    }),
    Preset(name: "Starfield Strings", affinity: 0.35, params: make {
        $0.zoom = 1.012; $0.zoomExp = 1.5; $0.sparkles = 1; $0.waveLine = 0.5; $0.waveThick = 1.5
        $0.decay = 0.96; $0.rot = 0.001; $0.hueDrift = 0.003; $0.zoomBeat = 0.015
    }),
]

/// Decides which preset is showing, when to change, and turns audio features into shader uniforms.
final class Director {
    var mode: StyleMode = .auto
    var locked = false
    private(set) var currentIndex = 0
    private var from = PresetParams()
    private var to = PresetParams()
    private var transition: Double = 1
    private var transitionDuration: Double = 1
    private var sinceSwitch: Double = 0
    private var time: Double = 0
    private var style: Float = 0.5
    private var flash: Float = 0
    private var hueOffset = Float.random(in: 0...1)
    private var seed = Float.random(in: 0...100)
    private var rotSign: Float = 1
    private var beatSmooth: Float = 0
    private(set) var lastEvent = ""
    /// Dominant hue of the current album art (from Spotify), if any. Pulls the palette toward the cover.
    var artHue: Float?
    private var artPull: Float = 0
    private var artHueSmooth: Float = 0

    init() {
        currentIndex = Int.random(in: 0..<presets.count)
        to = presets[currentIndex].params
        from = to
    }

    var presetName: String { presets[currentIndex].name }
    var styleValue: Float { style }

    func select(_ index: Int, duration: Double = 0.01) { switchTo(index % presets.count, duration: duration) }
    func next() { switchTo(pick(excluding: currentIndex, sequential: 1), duration: 1.5) }
    func previous() { switchTo((currentIndex - 1 + presets.count) % presets.count, duration: 1.5) }

    private func pick(excluding: Int, sequential: Int? = nil) -> Int {
        if let s = sequential { return (excluding + s) % presets.count }
        // Prefer presets whose affinity matches how rhythmic the music is.
        var weights: [Float] = presets.enumerated().map { i, p in
            i == excluding ? 0 : pow(max(0.05, 1 - abs(p.affinity - style)), 3)
        }
        let total = weights.reduce(0, +)
        var r = Float.random(in: 0..<total)
        for i in 0..<weights.count { r -= weights[i]; if r <= 0 { return i } }
        weights.removeAll()
        return (excluding + 1) % presets.count
    }

    private func switchTo(_ index: Int, duration: Double) {
        let t = Float(min(1, transition))
        from = PresetParams.lerp(from, to, Float(smooth(t)))
        currentIndex = index
        var p = presets[index].params
        // Small random variations so a preset never looks exactly the same twice.
        p.cx = Float.random(in: -0.05...0.05)
        p.cy = Float.random(in: -0.04...0.04)
        p.hueSpread *= Float.random(in: 0.7...1.4)
        to = p
        rotSign = Bool.random() ? 1 : -1
        hueOffset = Float.random(in: 0...1)
        seed = Float.random(in: 0...100)
        transition = 0
        transitionDuration = duration
        sinceSwitch = 0
    }

    private func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    func update(_ f: AudioFeatures, dt: Double, into u: inout Uniforms) {
        time += dt
        sinceSwitch += dt
        transition += dt / transitionDuration

        let targetStyle: Float
        switch mode {
        case .auto: targetStyle = f.rhythm
        case .electronic: targetStyle = 1
        case .classical: targetStyle = 0
        }
        style += (targetStyle - style) * Float(1 - exp(-dt / 1.5))
        let s = style
        let electronic = s > 0.5

        // ---- automatic preset changes ----------------------------------------
        if !locked && !f.silent {
            if electronic {
                if f.dropEvent && sinceSwitch > 6 {
                    switchTo(pick(excluding: currentIndex), duration: 0.15)
                    flash = 1
                    lastEvent = "DROP"
                } else if f.beatEvent && f.beatCount % 16 == 0 && sinceSwitch > 24 {
                    // Change on a phrase boundary; morph over ~2 beats.
                    let beat = f.bpm > 0 ? 60 / Double(f.bpm) : 0.5
                    switchTo(pick(excluding: currentIndex), duration: 2 * beat)
                    lastEvent = "phrase"
                }
            } else {
                if f.sectionEvent && sinceSwitch > 20 {
                    switchTo(pick(excluding: currentIndex), duration: 6)
                    lastEvent = "new section"
                } else if sinceSwitch > 50 {
                    switchTo(pick(excluding: currentIndex), duration: 9)
                    lastEvent = "drift"
                }
            }
        }

        // Downbeat accents for electronic music.
        if f.beatEvent && s > 0.5 && f.beatCount % 4 == 0 { flash = max(flash, 0.12 * s) }
        flash *= Float(exp(-dt / 0.18))

        // ---- params ------------------------------------------------------------
        var p = PresetParams.lerp(from, to, smooth(Float(min(1, transition))))
        // Classical: motion follows the dynamics, so pianissimo is calm and fortissimo is wild.
        let dyn = 0.35 + 0.95 * f.loudness
        let speed = s + (1 - s) * dyn
        p.zoom = 1 + (p.zoom - 1) * speed
        p.rot *= speed
        p.warp *= (1 - s) * (0.5 + dyn) + s
        p.swirl *= speed
        // Classical: no hard pulse, so beat-zoom is gentle and follows note onsets instead.
        p.zoomBeat *= 0.3 + 0.7 * s
        p.rotBeat *= 0.3 + 0.7 * s

        // Beat signal: predicted beat clock + real kicks for electronic, soft onsets for classical.
        let pulse = min(1.2, 0.75 * f.beatPulse + 0.5 * f.kick)
        let beatTarget = s * pulse + (1 - s) * 0.6 * f.onset
        beatSmooth = max(beatTarget, beatSmooth * Float(exp(-dt / 0.08)))

        // Color: electronic drifts freely; classical leans toward the harmony's key color and brightness.
        var freeHue = hueOffset + Float(time * 0.01)
        if let artHue {
            var da = artHue - artHueSmooth
            da -= da.rounded()
            artHueSmooth += da * Float(1 - exp(-dt / 2))
        }
        artPull += ((artHue == nil ? 0 : 0.65) - artPull) * Float(1 - exp(-dt / 3))
        var dArt = artHueSmooth + 0.06 * Float(sin(time * 0.07)) - freeHue
        dArt -= dArt.rounded()
        freeHue += dArt * artPull
        let keyHue = f.keyHue + 0.15 * (f.centroid - 0.5)
        var d = keyHue - freeHue
        d -= d.rounded()
        let hue = freeHue + d * (1 - s) * 0.8

        u.time = Float(time)
        u.dt = Float(min(dt * 60, 3))
        u.bass = f.bass; u.mid = f.mid; u.treb = f.treb
        u.bassAtt = f.bassAtt; u.midAtt = f.midAtt; u.trebAtt = f.trebAtt
        u.loudness = f.loudness
        u.kick = f.kick; u.hat = f.hat; u.onset = f.onset
        u.beat = beatSmooth
        u.beatPhase = f.beatPhase
        u.rhythm = s
        u.centroid = f.centroid
        u.hue = hue - floor(hue)
        u.flash = flash
        u.seed = seed
        u.rotSign = rotSign
        if f.silent { p.brightness *= 0.0 }
        u.p = p
    }
}
