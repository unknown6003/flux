import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal

/// GPU-accelerated physical Liquid Glass renderer (Metal compute shaders) for
/// the lock-screen music player card, activity pill, and giant `10:08` clock.
///
/// Computes real Snell's-law optical refraction over overscanned wallpaper
/// pixels, RGB chromatic dispersion at curved bevels, grazing-angle internal
/// reflection, and directional Fresnel specular rim highlights.
public final class LiquidGlassRenderer: @unchecked Sendable {
    public static let shared = LiquidGlassRenderer()

    private struct CardUniforms {
        var cardSizePt: SIMD2<Float>
        var cornerRadiusPt: Float
        var bevelWidthPt: Float
        var patchOriginInCardPt: SIMD2<Float>
        var patchSizePt: SIMD2<Float>
        var outputSizePx: SIMD2<UInt32>
        var scale: Float
        var refractionStrength: Float
        var dispersionStrength: Float
        var centerBlurPt: Float
        var rimBlurPt: Float
        var darkTintBase: Float
    }

    private struct ClockUniforms {
        var outputSizePx: SIMD2<UInt32>
        var scale: Float
        var bevelPx: Float
        var refractPx: Float
        var blurPt: Float
        var patchOriginPx: SIMD2<Float>
        var patchSizePx: SIMD2<Float>
    }

    private struct JFAUniforms {
        var size: SIMD2<UInt32>
        var step: Int32
        var bevelPx: Float
    }

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let cardPipeline: MTLComputePipelineState?
    private let jfaInitPipeline: MTLComputePipelineState?
    private let jfaStepPipeline: MTLComputePipelineState?
    private let jfaHeightPipeline: MTLComputePipelineState?
    private let clockPipeline: MTLComputePipelineState?

    private let clockCacheLock = NSLock()
    private var clockCache: [String: CGImage] = [:]

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.metalSource, options: nil) else {
            self.device = nil
            self.queue = nil
            self.cardPipeline = nil
            self.jfaInitPipeline = nil
            self.jfaStepPipeline = nil
            self.jfaHeightPipeline = nil
            self.clockPipeline = nil
            return
        }
        self.device = device
        self.queue = queue
        self.cardPipeline = library.makeFunction(name: "liquidGlassCardKernel")
            .flatMap { try? device.makeComputePipelineState(function: $0) }
        self.jfaInitPipeline = library.makeFunction(name: "jfaInitKernel")
            .flatMap { try? device.makeComputePipelineState(function: $0) }
        self.jfaStepPipeline = library.makeFunction(name: "jfaStepKernel")
            .flatMap { try? device.makeComputePipelineState(function: $0) }
        self.jfaHeightPipeline = library.makeFunction(name: "jfaHeightKernel")
            .flatMap { try? device.makeComputePipelineState(function: $0) }
        self.clockPipeline = library.makeFunction(name: "liquidGlassClockKernel")
            .flatMap { try? device.makeComputePipelineState(function: $0) }
    }

    public var isAvailable: Bool {
        device != nil && queue != nil && cardPipeline != nil && clockPipeline != nil
    }

    // MARK: - Card & Pill Liquid Glass

    /// Renders a physical Liquid Glass lens slab matching `cardFrame` over `backdrop`
    /// (with overscan so the curved perimeter refracts real surrounding wallpaper pixels).
    public func renderCardGlass(backdrop: CGImage,
                                screenFrame: CGRect,
                                cardFrame: CGRect,
                                cornerRadius: CGFloat,
                                scale: CGFloat = 2.0) -> CGImage? {
        guard let device, let queue, let pipeline = cardPipeline,
              screenFrame.width > 0, screenFrame.height > 0,
              cardFrame.width >= 8, cardFrame.height >= 8 else { return nil }

        let resolvedScale = max(1.0, min(scale, 3.0))
        let outW = max(2, Int((cardFrame.width * resolvedScale).rounded()))
        let outH = max(2, Int((cardFrame.height * resolvedScale).rounded()))

        // Overscan 48pt around the card so Snell's-law edge lensing pulls real
        // surrounding wallpaper pixels into the curved glass rim.
        let overscanPt: CGFloat = 48.0
        let expandedFrame = cardFrame.insetBy(dx: -overscanPt, dy: -overscanPt)
        guard let patchTex = makeBackdropPatchTexture(device: device,
                                                      backdrop: backdrop,
                                                      screenFrame: screenFrame,
                                                      targetScreenRect: expandedFrame,
                                                      scale: resolvedScale) else { return nil }

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: outW,
            height: outH,
            mipmapped: false
        )
        outDesc.usage = [.shaderWrite]
        outDesc.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: outDesc),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }

        let bevelWidth = Float(min(28.0, min(cardFrame.width, cardFrame.height) * 0.34))
        var uniforms = CardUniforms(
            cardSizePt: SIMD2<Float>(Float(cardFrame.width), Float(cardFrame.height)),
            cornerRadiusPt: Float(min(cornerRadius, min(cardFrame.width, cardFrame.height) * 0.5)),
            bevelWidthPt: bevelWidth,
            patchOriginInCardPt: SIMD2<Float>(Float(-overscanPt), Float(-overscanPt)),
            patchSizePt: SIMD2<Float>(Float(expandedFrame.width), Float(expandedFrame.height)),
            outputSizePx: SIMD2<UInt32>(UInt32(outW), UInt32(outH)),
            scale: Float(resolvedScale),
            refractionStrength: bevelWidth * 0.94,
            dispersionStrength: 0.16,
            centerBlurPt: 2.0,
            rimBlurPt: 3.8,
            darkTintBase: 0.10
        )

        enc.setComputePipelineState(pipeline)
        enc.setTexture(patchTex, index: 0)
        enc.setTexture(outTex, index: 1)
        enc.setBytes(&uniforms, length: MemoryLayout<CardUniforms>.stride, index: 0)
        dispatch2D(encoder: enc, pipeline: pipeline, width: outW, height: outH)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        return makeCGImage(from: outTex)
    }

    /// Convenience for capsule-shaped Liquid Glass pills (e.g., live activity pill).
    public func renderPillGlass(backdrop: CGImage,
                                screenFrame: CGRect,
                                pillFrame: CGRect,
                                scale: CGFloat = 2.0) -> CGImage? {
        renderCardGlass(backdrop: backdrop,
                        screenFrame: screenFrame,
                        cardFrame: pillFrame,
                        cornerRadius: pillFrame.height * 0.5,
                        scale: scale)
    }

    // MARK: - Sculpted Liquid Glass Clock

    /// Renders `timeText` as sculpted 3D refractive crystal glass digits over the
    /// exact wallpaper region behind `clockFrame` (in top-left screen-relative points).
    public func renderClockGlass(sourceKey: String?,
                                 backdrop: CGImage,
                                 canvasSizePt: CGSize,
                                 clockRectTopLeftPt: CGRect,
                                 timeText: String,
                                 fontSize: CGFloat,
                                 scale: CGFloat = 2.0) -> CGImage? {
        let cacheKey = "\(sourceKey ?? "none")|\(timeText)|\(Int(fontSize.rounded()))|\(Int(clockRectTopLeftPt.minX.rounded())),\(Int(clockRectTopLeftPt.minY.rounded())),\(Int(clockRectTopLeftPt.width.rounded())),\(Int(clockRectTopLeftPt.height.rounded()))"
        clockCacheLock.lock()
        if let cached = clockCache[cacheKey] {
            clockCacheLock.unlock()
            return cached
        }
        clockCacheLock.unlock()

        guard let device, let queue,
              let jfaInit = jfaInitPipeline,
              let jfaStep = jfaStepPipeline,
              let jfaHeight = jfaHeightPipeline,
              let clockPipe = clockPipeline,
              !timeText.isEmpty, fontSize > 8,
              canvasSizePt.width > 0, canvasSizePt.height > 0,
              clockRectTopLeftPt.width >= 16, clockRectTopLeftPt.height >= 16 else { return nil }

        let resolvedScale = max(1.0, min(scale, 2.0))
        let outW = max(16, Int((clockRectTopLeftPt.width * resolvedScale).rounded()))
        let outH = max(16, Int((clockRectTopLeftPt.height * resolvedScale).rounded()))

        guard let maskTex = rasterizeClockMask(device: device,
                                               text: timeText,
                                               fontSize: fontSize,
                                               widthPx: outW,
                                               heightPx: outH,
                                               scale: resolvedScale) else { return nil }

        // Overscan 40pt around the clock box so cylindrical digit refraction
        // bends real surrounding sky/foliage into the curved glass strokes.
        let overscanPt: CGFloat = 40.0
        let expandedTopLeft = clockRectTopLeftPt.insetBy(dx: -overscanPt, dy: -overscanPt)
        // Convert top-left rect into AppKit bottom-left screen rect for shared helper.
        let screenFrame = CGRect(origin: .zero, size: canvasSizePt)
        let expandedBottomLeft = CGRect(
            x: expandedTopLeft.minX,
            y: canvasSizePt.height - expandedTopLeft.maxY,
            width: expandedTopLeft.width,
            height: expandedTopLeft.height
        )
        guard let patchTex = makeBackdropPatchTexture(device: device,
                                                      backdrop: backdrop,
                                                      screenFrame: screenFrame,
                                                      targetScreenRect: expandedBottomLeft,
                                                      scale: resolvedScale) else { return nil }

        let seedDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float,
            width: outW,
            height: outH,
            mipmapped: false
        )
        seedDesc.usage = [.shaderRead, .shaderWrite]
        seedDesc.storageMode = .private

        let heightDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: outW,
            height: outH,
            mipmapped: false
        )
        heightDesc.usage = [.shaderRead, .shaderWrite]
        heightDesc.storageMode = .private

        let distDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: outW,
            height: outH,
            mipmapped: false
        )
        distDesc.usage = [.shaderRead, .shaderWrite]
        distDesc.storageMode = .private

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: outW,
            height: outH,
            mipmapped: false
        )
        outDesc.usage = [.shaderWrite]
        outDesc.storageMode = .shared

        guard let seedA = device.makeTexture(descriptor: seedDesc),
              let seedB = device.makeTexture(descriptor: seedDesc),
              let heightTex = device.makeTexture(descriptor: heightDesc),
              let distTex = device.makeTexture(descriptor: distDesc),
              let outTex = device.makeTexture(descriptor: outDesc),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }

        let bevelPx = Float(max(12.0, fontSize * resolvedScale * 0.068))
        var jfaUniforms = JFAUniforms(
            size: SIMD2<UInt32>(UInt32(outW), UInt32(outH)),
            step: 1,
            bevelPx: bevelPx
        )

        // Pass 1: seed outside boundary pixels.
        enc.setComputePipelineState(jfaInit)
        enc.setTexture(maskTex, index: 0)
        enc.setTexture(seedA, index: 1)
        enc.setBytes(&jfaUniforms, length: MemoryLayout<JFAUniforms>.stride, index: 0)
        dispatch2D(encoder: enc, pipeline: jfaInit, width: outW, height: outH)

        // Pass 2: 6 Jump Flooding passes (covers up to 63px inward stroke distance).
        var readSeed = seedA
        var writeSeed = seedB
        for step in [32, 16, 8, 4, 2, 1] {
            jfaUniforms.step = Int32(step)
            enc.setComputePipelineState(jfaStep)
            enc.setTexture(readSeed, index: 0)
            enc.setTexture(writeSeed, index: 1)
            enc.setBytes(&jfaUniforms, length: MemoryLayout<JFAUniforms>.stride, index: 0)
            dispatch2D(encoder: enc, pipeline: jfaStep, width: outW, height: outH)
            swap(&readSeed, &writeSeed)
        }

        // Pass 3: Euclidean distance + smooth 3D glass dome heightfield.
        enc.setComputePipelineState(jfaHeight)
        enc.setTexture(maskTex, index: 0)
        enc.setTexture(readSeed, index: 1)
        enc.setTexture(heightTex, index: 2)
        enc.setTexture(distTex, index: 3)
        enc.setBytes(&jfaUniforms, length: MemoryLayout<JFAUniforms>.stride, index: 0)
        dispatch2D(encoder: enc, pipeline: jfaHeight, width: outW, height: outH)

        // Pass 4: Snell's-law refraction + chromatic dispersion + crystal bevel lighting.
        var clockUniforms = ClockUniforms(
            outputSizePx: SIMD2<UInt32>(UInt32(outW), UInt32(outH)),
            scale: Float(resolvedScale),
            bevelPx: bevelPx,
            refractPx: Float(fontSize * resolvedScale * 0.145),
            blurPt: 5.5,
            patchOriginPx: SIMD2<Float>(Float(overscanPt * resolvedScale), Float(overscanPt * resolvedScale)),
            patchSizePx: SIMD2<Float>(Float(patchTex.width), Float(patchTex.height))
        )
        enc.setComputePipelineState(clockPipe)
        enc.setTexture(maskTex, index: 0)
        enc.setTexture(heightTex, index: 1)
        enc.setTexture(distTex, index: 2)
        enc.setTexture(patchTex, index: 3)
        enc.setTexture(outTex, index: 4)
        enc.setBytes(&clockUniforms, length: MemoryLayout<ClockUniforms>.stride, index: 0)
        dispatch2D(encoder: enc, pipeline: clockPipe, width: outW, height: outH)

        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        guard let image = makeCGImage(from: outTex) else { return nil }
        clockCacheLock.lock()
        if clockCache.count > 6 { clockCache.removeAll() }
        clockCache[cacheKey] = image
        clockCacheLock.unlock()
        return image
    }

    // MARK: - Texture Helpers

    private func makeBackdropPatchTexture(device: MTLDevice,
                                          backdrop: CGImage,
                                          screenFrame: CGRect,
                                          targetScreenRect: CGRect,
                                          scale: CGFloat) -> MTLTexture? {
        let texW = max(4, Int((targetScreenRect.width * scale).rounded()))
        let texH = max(4, Int((targetScreenRect.height * scale).rounded()))
        let bytesPerRow = texW * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * texH)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: &pixels,
            width: texW,
            height: texH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        // Map full screenFrame into the targetScreenRect coordinate space (AppKit Y-up).
        let drawRect = CGRect(
            x: (screenFrame.minX - targetScreenRect.minX) * scale,
            y: (screenFrame.minY - targetScreenRect.minY) * scale,
            width: screenFrame.width * scale,
            height: screenFrame.height * scale
        )
        ctx.draw(backdrop, in: drawRect)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: texW,
            height: texH,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        pixels.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                tex.replace(region: MTLRegionMake2D(0, 0, texW, texH),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: bytesPerRow)
            }
        }
        return tex
    }

    private func rasterizeClockMask(device: MTLDevice,
                                    text: String,
                                    fontSize: CGFloat,
                                    widthPx: Int,
                                    heightPx: Int,
                                    scale: CGFloat) -> MTLTexture? {
        let cgPath = ClockGlyphShape.makeCGPath(text: text, fontSize: fontSize * scale)
        let bounds = cgPath.boundingBoxOfPath
        guard !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: widthPx * heightPx)
        guard let ctx = CGContext(
            data: &pixels,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: widthPx,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        // CoreText path is Y-up, matching CGContext Y-up directly (no flip needed!).
        let tx = CGFloat(widthPx) * 0.5 - bounds.midX
        let ty = CGFloat(heightPx) * 0.5 - bounds.midY
        ctx.translateBy(x: tx, y: ty)
        ctx.addPath(cgPath)
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fillPath()

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: widthPx,
            height: heightPx,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        pixels.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                tex.replace(region: MTLRegionMake2D(0, 0, widthPx, heightPx),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: widthPx)
            }
        }
        return tex
    }

    private func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func dispatch2D(encoder: MTLComputeCommandEncoder,
                            pipeline: MTLComputePipelineState,
                            width: Int,
                            height: Int) {
        let w = min(pipeline.threadExecutionWidth, max(1, width))
        let h = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / w, height))
        let group = MTLSize(width: w, height: h, depth: 1)
        let grid = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
    }

    // MARK: - Metal Shaders

    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CardUniforms {
        float2 cardSizePt;
        float cornerRadiusPt;
        float bevelWidthPt;
        float2 patchOriginInCardPt;
        float2 patchSizePt;
        uint2 outputSizePx;
        float scale;
        float refractionStrength;
        float dispersionStrength;
        float centerBlurPt;
        float rimBlurPt;
        float darkTintBase;
    };

    struct ClockUniforms {
        uint2 outputSizePx;
        float scale;
        float bevelPx;
        float refractPx;
        float blurPt;
        float2 patchOriginPx;
        float2 patchSizePx;
    };

    struct JFAUniforms {
        uint2 size;
        int step;
        float bevelPx;
    };

    constant float2 kDiscOffsets[12] = {
        float2( 1.000,  0.000), float2( 0.500,  0.866), float2(-0.500,  0.866),
        float2(-1.000,  0.000), float2(-0.500, -0.866), float2( 0.500, -0.866),
        float2( 0.433,  0.250), float2( 0.000,  0.500), float2(-0.433,  0.250),
        float2(-0.433, -0.250), float2( 0.000, -0.500), float2( 0.433, -0.250)
    };

    // Continuous squircle-blended rounded rectangle SDF (matches Apple continuous corners).
    static inline float sdRoundedBox(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - (halfSize - float2(r));
        float outside = length(max(q, 0.0));
        float inside = min(max(q.x, q.y), 0.0);
        return outside + inside - r;
    }

    static inline float3 sampleSoftRGB(texture2d<float, access::sample> tex,
                                       sampler s,
                                       float2 uv,
                                       float2 blurUV) {
        float3 acc = tex.sample(s, uv).rgb * 2.0;
        float weight = 2.0;
        for (int i = 0; i < 12; ++i) {
            float w = (i < 6) ? 0.65 : 1.0;
            acc += tex.sample(s, uv + kDiscOffsets[i] * blurUV).rgb * w;
            weight += w;
        }
        return acc / weight;
    }

    kernel void liquidGlassCardKernel(texture2d<float, access::sample> patchTex [[texture(0)]],
                                      texture2d<float, access::write> outTex [[texture(1)]],
                                      constant CardUniforms& u [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.outputSizePx.x || gid.y >= u.outputSizePx.y) { return; }

        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

        // Local point coordinates centered at (0, 0), Y-down matching texture space.
        float2 ptTopLeft = (float2(gid) + 0.5) / u.scale;
        float2 halfSize = u.cardSizePt * 0.5;
        float2 p = ptTopLeft - halfSize;

        float d = sdRoundedBox(p, halfSize, u.cornerRadiusPt);
        float edgeAA = smoothstep(0.60, -0.60, d);
        if (edgeAA <= 0.001) {
            outTex.write(float4(0.0), gid);
            return;
        }

        // Smooth outward unit normal from centered finite differences of the SDF.
        const float eps = 0.75;
        float2 gradRaw = float2(
            sdRoundedBox(p + float2(eps, 0.0), halfSize, u.cornerRadiusPt) -
            sdRoundedBox(p - float2(eps, 0.0), halfSize, u.cornerRadiusPt),
            sdRoundedBox(p + float2(0.0, eps), halfSize, u.cornerRadiusPt) -
            sdRoundedBox(p - float2(0.0, eps), halfSize, u.cornerRadiusPt)
        );
        float gradLen = max(length(gradRaw), 1e-4);
        float2 grad = gradRaw / gradLen;

        float distIn = max(0.0, -d);
        float t = clamp(distIn / max(u.bevelWidthPt, 1.0), 0.0, 1.0);

        // Convex physical glass lens bevel: steep slope near perimeter, flat optical plateau in center.
        float rimSlope = pow(1.0 - t, 2.15);
        float2 bevelDispPt = grad * (u.refractionStrength * rimSlope);
        // Subtle macro lens pull across the glass slab.
        float2 macroDispPt = -p * 0.016;

        // Chromatic dispersion scales with bevel curvature (zero fringing in flat center, vivid prism at corners).
        float dispSplit = u.dispersionStrength;
        float2 ptR = ptTopLeft + bevelDispPt * (1.0 - dispSplit) + macroDispPt;
        float2 ptG = ptTopLeft + bevelDispPt + macroDispPt;
        float2 ptB = ptTopLeft + bevelDispPt * (1.0 + dispSplit * 1.12) + macroDispPt;

        float2 uvR = (ptR - u.patchOriginInCardPt) / u.patchSizePt;
        float2 uvG = (ptG - u.patchOriginInCardPt) / u.patchSizePt;
        float2 uvB = (ptB - u.patchOriginInCardPt) / u.patchSizePt;

        float blurPt = mix(u.rimBlurPt, u.centerBlurPt, t);
        float2 blurUV = float2(blurPt) / u.patchSizePt;

        float r = sampleSoftRGB(patchTex, s, uvR, blurUV).r;
        float g = sampleSoftRGB(patchTex, s, uvG, blurUV).g;
        float b = sampleSoftRGB(patchTex, s, uvB, blurUV).b;
        float3 refracted = float3(r, g, b);

        // Thick optical glass slightly enriches color saturation.
        float luma = dot(refracted, float3(0.2126, 0.7152, 0.0722));
        refracted = mix(float3(luma), refracted, 1.12);

        // Adaptive optical scrim: crystal clear on dark scenes, gentle darkening on bright sky for text contrast.
        float darkScrim = mix(u.darkTintBase, 0.26, smoothstep(0.42, 0.85, luma));
        float3 glass = refracted * (1.0 - darkScrim);

        // Subtle grazing-angle total-internal-reflection depth band just inside the rim.
        float innerBand = smoothstep(0.6, 3.2, distIn) * (1.0 - smoothstep(3.2, 11.0, distIn));
        glass *= (1.0 - 0.11 * innerBand);

        // Delicate top-to-bottom optical surface sheen.
        float verticalGrad = clamp(ptTopLeft.y / max(u.cardSizePt.y, 1.0), 0.0, 1.0);
        glass += float3(0.038 * (1.0 - verticalGrad) + 0.015 * verticalGrad);

        // Inner caustic glow right along the bevel shoulder.
        float caustic = pow(1.0 - t, 3.4) * smoothstep(0.0, 2.5, distIn);
        glass += (float3(0.85, 0.90, 0.96) * 0.10 + refracted * 0.08) * caustic;

        // Crisp directional Fresnel specular rim catchlight (top-left key + bottom-right bounce).
        float lightTL = max(0.0, dot(grad, normalize(float2(-0.48, -0.88))));
        float lightBR = max(0.0, dot(grad, normalize(float2( 0.48,  0.88))));
        float topEdge = max(0.0, -grad.y);
        float rimSharp = exp(-distIn * 1.18);
        float rimIntensity = rimSharp * (0.20 + 0.56 * pow(lightTL, 2.0) + 0.34 * pow(lightBR, 2.0) + 0.18 * topEdge);

        float3 rimTint = mix(float3(1.0), clamp(refracted * 1.35 + 0.25, 0.0, 1.0), 0.28);
        glass = clamp(glass + rimTint * rimIntensity, 0.0, 1.0);

        outTex.write(float4(glass * edgeAA, edgeAA), gid);
    }

    // MARK: - Clock Jump Flooding + Sculpted Liquid Glass Digits

    kernel void jfaInitKernel(texture2d<float, access::read> maskTex [[texture(0)]],
                              texture2d<float, access::write> seedTex [[texture(1)]],
                              constant JFAUniforms& u [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.size.x || gid.y >= u.size.y) { return; }
        float m = maskTex.read(gid).r;
        if (m < 0.5) {
            seedTex.write(float4(float(gid.x), float(gid.y), 0.0, 0.0), gid);
        } else {
            seedTex.write(float4(-1.0, -1.0, 0.0, 0.0), gid);
        }
    }

    kernel void jfaStepKernel(texture2d<float, access::read> srcSeed [[texture(0)]],
                              texture2d<float, access::write> dstSeed [[texture(1)]],
                              constant JFAUniforms& u [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.size.x || gid.y >= u.size.y) { return; }
        float2 pos = float2(gid);
        float2 best = srcSeed.read(gid).xy;
        float bestDistSq = (best.x >= 0.0) ? dot(best - pos, best - pos) : 1e20;

        int2 maxCoord = int2(int(u.size.x) - 1, int(u.size.y) - 1);
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                if (dx == 0 && dy == 0) { continue; }
                int2 nc = clamp(int2(gid) + int2(dx, dy) * u.step, int2(0), maxCoord);
                float2 cand = srcSeed.read(uint2(nc)).xy;
                if (cand.x >= 0.0) {
                    float d2 = dot(cand - pos, cand - pos);
                    if (d2 < bestDistSq) {
                        bestDistSq = d2;
                        best = cand;
                    }
                }
            }
        }
        dstSeed.write(float4(best, 0.0, 0.0), gid);
    }

    kernel void jfaHeightKernel(texture2d<float, access::read> maskTex [[texture(0)]],
                                texture2d<float, access::read> seedTex [[texture(1)]],
                                texture2d<float, access::write> heightTex [[texture(2)]],
                                texture2d<float, access::write> distTex [[texture(3)]],
                                constant JFAUniforms& u [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.size.x || gid.y >= u.size.y) { return; }
        float m = maskTex.read(gid).r;
        if (m < 0.02) {
            heightTex.write(float4(0.0), gid);
            distTex.write(float4(0.0), gid);
            return;
        }
        float2 seed = seedTex.read(gid).xy;
        float distPx = (seed.x >= 0.0) ? length(float2(gid) - seed) : u.bevelPx;
        float norm = clamp(distPx / max(u.bevelPx, 1.0), 0.0, 1.0);
        // Smooth circular-arc 3D glass rod dome profile across each digit stroke.
        float h = sqrt(max(0.0, 1.0 - (1.0 - norm) * (1.0 - norm)));
        heightTex.write(float4(h, 0.0, 0.0, 0.0), gid);
        distTex.write(float4(distPx, 0.0, 0.0, 0.0), gid);
    }

    kernel void liquidGlassClockKernel(texture2d<float, access::read> maskTex [[texture(0)]],
                                       texture2d<float, access::read> heightTex [[texture(1)]],
                                       texture2d<float, access::read> distTex [[texture(2)]],
                                       texture2d<float, access::sample> patchTex [[texture(3)]],
                                       texture2d<float, access::write> outTex [[texture(4)]],
                                       constant ClockUniforms& u [[buffer(0)]],
                                       uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.outputSizePx.x || gid.y >= u.outputSizePx.y) { return; }

        float alpha = maskTex.read(gid).r;
        if (alpha <= 0.002) {
            outTex.write(float4(0.0), gid);
            return;
        }

        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        int2 maxC = int2(int(u.outputSizePx.x) - 1, int(u.outputSizePx.y) - 1);
        int2 c = int2(gid);

        // Wide 5x5 smoothed gradient of the 3D heightfield for silky lens normals.
        float gx = 0.0;
        float gy = 0.0;
        for (int dy = -2; dy <= 2; ++dy) {
            float wy = (abs(dy) == 0) ? 3.0 : ((abs(dy) == 1) ? 2.0 : 1.0);
            for (int dx = -2; dx <= 2; ++dx) {
                float wx = (abs(dx) == 0) ? 3.0 : ((abs(dx) == 1) ? 2.0 : 1.0);
                float h = heightTex.read(uint2(clamp(c + int2(dx, dy), int2(0), maxC))).r;
                if (dx != 0) { gx += h * float(dx) * wy; }
                if (dy != 0) { gy += h * float(dy) * wx; }
            }
        }
        gx /= 34.0;
        gy /= 34.0;

        float hCenter = heightTex.read(gid).r;
        float distPx = distTex.read(gid).r;

        // Outward 3D surface normal pointing down the bevel toward the glyph boundary.
        float3 normal = normalize(float3(-gx * 5.2, -gy * 5.2, 1.0));

        // Snell's-law cylindrical refraction + RGB chromatic dispersion through each glass stroke.
        float2 basePx = u.patchOriginPx + float2(gid) + 0.5;
        float2 dispPx = normal.xy * u.refractPx;

        float2 uvR = (basePx + dispPx * 0.87) / u.patchSizePx;
        float2 uvG = (basePx + dispPx * 1.00) / u.patchSizePx;
        float2 uvB = (basePx + dispPx * 1.15) / u.patchSizePx;

        float2 blurUV = float2(u.blurPt * u.scale) / u.patchSizePx;
        float r = sampleSoftRGB(patchTex, s, uvR, blurUV).r;
        float g = sampleSoftRGB(patchTex, s, uvG, blurUV).g;
        float b = sampleSoftRGB(patchTex, s, uvB, blurUV).b;
        float3 refracted = float3(r, g, b);

        // Enrich refracted scene tones inside the thick crystal glass.
        float luma = dot(refracted, float3(0.2126, 0.7152, 0.0722));
        refracted = mix(float3(luma), refracted, 1.18);

        // Luminous frosted crystal-glass body (Apple lock-screen signature translucency):
        // bright & legible against dark skies/foliage while preserving warm/cool refractions.
        float topLit = clamp(-normal.y * 0.5 + 0.5, 0.0, 1.0);
        float fresnel = pow(clamp(1.0 - normal.z, 0.0, 1.0), 1.75);
        float bodyScatter = 0.28 + 0.24 * topLit + 0.08 * hCenter;
        float3 glass = mix(refracted * 1.15, float3(0.96, 0.97, 0.99), bodyScatter);

        // Studio specular reflections across the curved 3D glass cross-section.
        float3 lightTL = normalize(float3(-0.32, -0.82, 0.48));
        float3 lightBR = normalize(float3( 0.36,  0.72, 0.59));
        float specTL = pow(max(0.0, dot(normal, lightTL)), 5.5);
        float specBR = pow(max(0.0, dot(normal, lightBR)), 4.5);
        glass += float3(1.0) * (0.34 * specTL + 0.20 * specBR + 0.22 * fresnel);

        // Razor-crisp bright specular rim right at the beveled glyph outline.
        float rim = exp(-distPx * (0.48 / max(u.scale * 0.5, 0.5)));
        glass = mix(glass, float3(1.0), rim * (0.46 + 0.40 * topLit));

        glass = clamp(glass, 0.0, 1.0);
        outTex.write(float4(glass * alpha, alpha), gid);
    }
    """
}
