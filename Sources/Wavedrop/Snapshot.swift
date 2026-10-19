import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `Wavedrop --snapshot out.png`: renders every preset offscreen with synthetic music into one contact sheet.
enum Snapshot {
    static func run(path: String) throws {
        let device = MTLCreateSystemDefaultDevice()!
        let w = 640, h = 360, cols = 4
        let rows = (presets.count + cols - 1) / cols
        let ctx = CGContext(data: nil, width: w * cols, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let target = device.makeTexture(descriptor: td)!

        for (i, preset) in presets.enumerated() {
            let electronic = preset.affinity > 0.5
            let src = DemoSource()
            let r = try Renderer(device: device, pixelFormat: .bgra8Unorm, source: src)
            r.director.mode = electronic ? .electronic : .classical
            r.director.select(i)
            r.director.locked = true
            // 8 s of audio at 60 fps.
            var chunks: [[Float]] = []
            var n = 0
            for _ in 0..<480 {
                chunks.append((0..<800).map { k in
                    let t = Double(n + k) / 48_000
                    return electronic ? DemoSource.electronic(t) : DemoSource.strings(t + 2)
                })
                n += 800
            }
            r.renderOffscreen(samples: chunks, dt: 1.0 / 60, size: CGSize(width: w, height: h), target: target)
            print(String(format: "%2d %@", i, r.debugState))

            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let x = (i % cols) * w, y = (rows - 1 - i / cols) * h
            ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
        }
        let out = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(path)")
    }
}
