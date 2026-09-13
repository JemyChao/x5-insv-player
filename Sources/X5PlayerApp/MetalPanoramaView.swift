import AppKit
import MetalKit
import SwiftUI
import simd

enum ProjectionMode: Int, CaseIterable, Identifiable {
    case rectilinear = 0
    case equirectangular = 1
    case littlePlanet = 2
    case rawLenses = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .rectilinear: return "Perspective"
        case .equirectangular: return "Equirect"
        case .littlePlanet: return "Little planet"
        case .rawLenses: return "Raw lenses"
        }
    }
}

struct MetalPanoramaView: NSViewRepresentable {
    let renderer: PanoramaRenderer

    func makeNSView(context: Context) -> MTKView { renderer.makeView() }
    func updateNSView(_ nsView: MTKView, context: Context) { }
}

/// MTKView subclass so the scroll wheel and the keyboard reach the renderer.
final class PanoramaMTKView: MTKView {
    var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
    var onKey: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.modifierFlags.contains(.option))
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        if characters.isEmpty { super.keyDown(with: event) } else { onKey?(characters) }
    }
}

/// Uploads both planes of both lens tracks and draws the stitched view.
///
/// Everything here runs on the main thread (MTKView drives its delegate from
/// the run loop), and it deliberately avoids touching the `@MainActor` model so
/// the draw path stays free of actor hops.
final class PanoramaRenderer: NSObject, MTKViewDelegate {
    let engine = PlaybackEngine()

    var profile = LensProfile()
    var projection: ProjectionMode = .rectilinear
    var showGuides = false
    var seamDebug = false
    var showHorizon = false
    var exposure: Float = 1
    var stabilization: Stabilization = .off
    var imuYaw: IMUYaw = .measured
    var motion: MotionTrack?
    var useBT2020 = false
    var tonemapHLG = false

    /// Media time of the frame currently uploaded to the textures.
    private var presentedTime: Double = 0

    private(set) var setupError: String?
    private(set) var fieldOfView: Float = 1.42
    private(set) var yaw: Float = 0
    private(set) var pitch: Float = 0

    /// Called on the main thread whenever the look direction changes, so the UI
    /// can show it without polling.
    var onLookChanged: ((Float, Float, Float) -> Void)?

    /// Set-up happens lazily on first display, so failures are pushed out
    /// rather than polled; without this a shader failure is just a black frame.
    var onSetupError: ((String) -> Void)?

    private func report(_ text: String) {
        setupError = text
        onSetupError?(text)
    }

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var view: PanoramaMTKView?

    // The CVMetalTexture wrappers have to outlive the MTLTexture handles taken
    // from them, so they are held alongside.
    private var wrappers: [CVMetalTexture] = []
    private var textures: [MTLTexture?] = [nil, nil, nil, nil]

    func makeView() -> MTKView {
        if let existing = view { return existing }

        guard let device = MTLCreateSystemDefaultDevice() else {
            report("No usable Metal device found.")
            return MTKView(frame: .zero, device: nil)
        }
        self.device = device

        let view = PanoramaMTKView(frame: .zero, device: device)
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0.020, green: 0.024, blue: 0.027, alpha: 1)

        commandQueue = device.makeCommandQueue()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        do {
            let library = try PanoramaRenderer.makeLibrary(device: device)
            guard let vertexFunction = library.makeFunction(name: "fullscreenVertex"),
                  let fragmentFunction = library.makeFunction(name: "panoramaFragment") else {
                throw PanoramaError.shaderMissing
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            report("Metal shader build failed: \(error.localizedDescription)")
        }

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(pan)
        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        view.addGestureRecognizer(magnify)
        view.onScroll = { [weak self] dx, dy, panning in self?.handleScroll(dx: dx, dy: dy, panning: panning) }
        view.onKey = { [weak self] key in self?.handleKey(key) }

        self.view = view
        return view
    }

    /// SwiftPM copies the shader next to the binary; Xcode may also have
    /// compiled it into the module's default library. Try the compiled one and
    /// fall back to building it from source at launch.
    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let compiled = try? device.makeDefaultLibrary(bundle: .module),
           compiled.makeFunction(name: "panoramaFragment") != nil {
            return compiled
        }
        let url = Bundle.module.url(forResource: "Panorama", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "Panorama", withExtension: "metal")
        guard let url else { throw PanoramaError.shaderMissing }
        let source = try String(contentsOf: url, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
    }

    // MARK: - Look control

    func resetView() {
        yaw = 0
        pitch = 0
        fieldOfView = 1.42
        reportLook()
    }

    func setFieldOfView(_ value: Float) {
        fieldOfView = min(max(value, 0.35), 2.60)
        reportLook()
    }

    func look(yaw newYaw: Float, pitch newPitch: Float) {
        yaw = newYaw.truncatingRemainder(dividingBy: .pi * 2)
        pitch = min(max(newPitch, -1.45), 1.45)
        reportLook()
    }

    private func reportLook() {
        onLookChanged?(yaw, pitch, fieldOfView)
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        // Drag speed follows the zoom so a tight crop still feels one to one.
        let speed = fieldOfView * 0.0022
        look(yaw: yaw - Float(translation.x) * speed, pitch: pitch + Float(translation.y) * speed)
        gesture.setTranslation(.zero, in: view)
    }

    @objc private func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
        setFieldOfView(fieldOfView - Float(gesture.magnification) * 0.45)
        gesture.magnification = 0
    }

    private func handleScroll(dx: CGFloat, dy: CGFloat, panning: Bool) {
        if panning {
            let speed = fieldOfView * 0.0022
            look(yaw: yaw - Float(dx) * speed, pitch: pitch + Float(dy) * speed)
        } else {
            setFieldOfView(fieldOfView - Float(dy) * 0.006)
        }
    }

    private func handleKey(_ key: String) {
        switch key {
        case "r", "R":
            resetView()
        case "\u{1B}":
            resetView()
        default:
            break
        }
    }

    // MARK: - Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard let pipeline, let commandQueue else { return }

        if let frame = engine.currentFrame() {
            upload(frame)
            presentedTime = frame.time
        }

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipeline)
        for index in 0..<4 {
            encoder.setFragmentTexture(textures[index], index: index)
        }
        var uniforms = makeUniforms(aspect: Float(view.drawableSize.width / max(view.drawableSize.height, 1)),
                                    height: Float(max(view.drawableSize.height, 1)))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PanoramaUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func makeUniforms(aspect: Float, height: Float) -> PanoramaUniforms {
        let userRotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        // Sampled at the timestamp of the frame actually on screen, not at the
        // clock. The view redraws at 60 Hz while the capture runs at 30, so
        // reading the clock rotates each frame differently on its two draws and
        // turns stabilisation into a 60 Hz vibration.
        let correction = motion?.correction(at: presentedTime, mode: stabilization, imuYaw: imuYaw.radians)
            ?? MotionTrack.identity
        let combined = (correction * userRotation).normalized

        let front = profile.swapTracks ? profile.back : profile.front
        let back = profile.swapTracks ? profile.front : profile.back

        let ready = textures[0] != nil && textures[1] != nil && textures[2] != nil && textures[3] != nil

        return PanoramaUniforms(
            view: combined.vector,
            lensARot: front.rotation.vector,
            lensBRot: back.rotation.vector,
            lensAGeom: front.geometryVector,
            lensBGeom: back.geometryVector,
            lensAOpt: front.optionVector,
            lensBOpt: back.optionVector,
            lensAPoly: front.polynomialVector,
            lensBPoly: back.polynomialVector,
            render: SIMD4<Float>(fieldOfView, aspect, profile.blendRadians, exposure),
            flags: SIMD4<Float>(Float(projection.rawValue),
                                ready ? 1 : 0,
                                showGuides ? 1 : 0,
                                seamDebug ? 1 : 0),
            color: SIMD4<Float>(useBT2020 ? 1 : 0, tonemapHLG ? 1 : 0, 0, 0),
            horizonUp: horizonUniform(combined, height: height),
            overlay: SIMD4<Float>(showHorizon && motion != nil ? 1 : 0,
                                  showHorizon ? 1 : 0,
                                  2.0 / height * 1.5,
                                  0)
        )
    }

    /// Where the stabilisation believes level is, carried into view space, plus
    /// a line width that stays about three pixels however far the view is
    /// zoomed in.
    ///
    /// With stabilisation on the line necessarily lands on the window's centre
    /// line and says nothing. Switch stabilisation off and it becomes the one
    /// useful test: the footage shows the real horizon, so a line that tracks
    /// it means the estimate is sound and the fault is in applying it, and a
    /// line at an angle to it means the heading frame is wrong.
    private func horizonUniform(_ combined: simd_quatf, height: Float) -> SIMD4<Float> {
        let measured = motion?.estimatedUp(at: presentedTime) ?? SIMD3<Float>(0, 1, 0)
        let frame = simd_quatf(angle: imuYaw.radians, axis: SIMD3<Float>(0, 1, 0))
        let inView = combined.inverse.act(frame.inverse.act(measured))
        let radiansPerPixel = fieldOfView / max(height, 1)
        return SIMD4<Float>(inView.x, inView.y, inView.z, max(radiansPerPixel * 1.5, 1e-5))
    }

    private func upload(_ frame: CaptureReader.FramePair) {
        guard let textureCache else { return }
        var newWrappers: [CVMetalTexture] = []
        var newTextures: [MTLTexture?] = [nil, nil, nil, nil]

        func makePlane(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> MTLTexture? {
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            guard width > 0, height > 0 else { return nil }
            var reference: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil,
                                                                   format, width, height, plane, &reference)
            guard status == kCVReturnSuccess, let reference else { return nil }
            newWrappers.append(reference)
            return CVMetalTextureGetTexture(reference)
        }

        newTextures[0] = makePlane(frame.left, plane: 0, format: .r8Unorm)
        newTextures[1] = makePlane(frame.left, plane: 1, format: .rg8Unorm)
        newTextures[2] = makePlane(frame.right, plane: 0, format: .r8Unorm)
        newTextures[3] = makePlane(frame.right, plane: 1, format: .rg8Unorm)

        guard newTextures.allSatisfy({ $0 != nil }) else { return }
        wrappers = newWrappers
        textures = newTextures
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}

enum PanoramaError: LocalizedError {
    case shaderMissing

    var errorDescription: String? {
        switch self {
        case .shaderMissing: return "Panorama.metal resource not found."
        }
    }
}

/// Every field is a float4 so the Swift and Metal layouts cannot drift apart
/// through alignment padding.
struct PanoramaUniforms {
    var view: SIMD4<Float>
    var lensARot: SIMD4<Float>
    var lensBRot: SIMD4<Float>
    var lensAGeom: SIMD4<Float>
    var lensBGeom: SIMD4<Float>
    var lensAOpt: SIMD4<Float>
    var lensBOpt: SIMD4<Float>
    var lensAPoly: SIMD4<Float>
    var lensBPoly: SIMD4<Float>
    var render: SIMD4<Float>
    var flags: SIMD4<Float>
    var color: SIMD4<Float>
    var horizonUp: SIMD4<Float>
    var overlay: SIMD4<Float>
}
