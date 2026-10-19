import MetalKit
import QuartzCore

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let warpPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private var feedback: [MTLTexture] = []
    private var current = 0

    let source: AudioSource
    let analyzer: AudioAnalyzer
    let director = Director()
    private var features = AudioFeatures()
    private var uniforms = Uniforms()
    private var samples: [Float] = []
    private var lastTime = CACurrentMediaTime()
    /// Called once per frame on the main thread (HUD updates).
    var onFrame: ((AudioFeatures, Director) -> Void)?

    /// Feedback buffers are capped so 5K/6K displays stay smooth.
    private let maxFeedbackDimension: CGFloat = 2560

    convenience init(view: MTKView, source: AudioSource) throws {
        try self.init(device: view.device, pixelFormat: view.colorPixelFormat, source: source)
    }

    init(device: MTLDevice?, pixelFormat: MTLPixelFormat, source: AudioSource) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Wavedrop", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is not available"])
        }
        self.device = device
        self.queue = queue
        self.source = source
        analyzer = AudioAnalyzer(sampleRate: source.sampleRate)

        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let vfn = library.makeFunction(name: "vmain")
        let warpDesc = MTLRenderPipelineDescriptor()
        warpDesc.vertexFunction = vfn
        warpDesc.fragmentFunction = library.makeFunction(name: "warpFrag")
        warpDesc.colorAttachments[0].pixelFormat = .rgba16Float
        warpPipeline = try device.makeRenderPipelineState(descriptor: warpDesc)

        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.vertexFunction = vfn
        compDesc.fragmentFunction = library.makeFunction(name: "compositeFrag")
        compDesc.colorAttachments[0].pixelFormat = pixelFormat
        compositePipeline = try device.makeRenderPipelineState(descriptor: compDesc)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        makeFeedback(for: size)
    }

    private func makeFeedback(for size: CGSize) {
        let scale = min(1, maxFeedbackDimension / max(size.width, size.height, 1))
        let w = max(16, Int(size.width * scale)), h = max(16, Int(size.height * scale))
        if let t = feedback.first, t.width == w, t.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        feedback = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        // Clear new textures.
        if let cb = queue.makeCommandBuffer() {
            for t in feedback {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = t
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                rp.colorAttachments[0].storeAction = .store
                cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
            }
            cb.commit()
        }
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTime, 1.0 / 240), 0.1)
        lastTime = now
        source.ring.readNew(into: &samples)
        if feedback.isEmpty { makeFeedback(for: view.drawableSize) }
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        encodeFrame(cb, samples: samples, dt: dt, target: drawable.texture)
        cb.present(drawable)
        cb.commit()
    }

    /// Renders offscreen frames from given audio (used by `--snapshot` to check visuals without a display).
    func renderOffscreen(samples chunks: [[Float]], dt: Double, size: CGSize, target: MTLTexture) {
        makeFeedback(for: size)
        for chunk in chunks {
            guard let cb = queue.makeCommandBuffer() else { return }
            encodeFrame(cb, samples: chunk, dt: dt, target: target)
            cb.commit()
            cb.waitUntilCompleted()
        }
    }

    var debugState: String {
        String(format: "%@ style %.2f bpm %.1f rhythm %.2f loud %.2f", director.presetName, director.styleValue,
               features.bpm, features.rhythm, features.loudness)
    }

    private func encodeFrame(_ cb: MTLCommandBuffer, samples: [Float], dt: Double, target: MTLTexture) {
        analyzer.process(samples, into: &features)
        director.update(features, dt: dt, into: &uniforms)
        onFrame?(features, director)
        guard feedback.count == 2 else { return }

        let src = feedback[current], dst = feedback[1 - current]
        uniforms.resX = Float(dst.width)
        uniforms.resY = Float(dst.height)

        // Pass 1: warp previous frame + draw new elements into the feedback buffer.
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = dst
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(warpPipeline)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            features.wave.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            features.spectrum.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
            enc.setFragmentTexture(src, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // Pass 2: composite to screen.
        let vp = MTLRenderPassDescriptor()
        vp.colorAttachments[0].texture = target
        vp.colorAttachments[0].loadAction = .dontCare
        vp.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: vp) {
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(dst, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        current = 1 - current
    }

    func adjustLatency(by seconds: Double) {
        analyzer.latencyCompensation = max(-0.2, min(0.3, analyzer.latencyCompensation + seconds))
    }
}
