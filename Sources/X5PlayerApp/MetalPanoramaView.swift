import MetalKit
import SwiftUI

struct MetalPanoramaView: NSViewRepresentable {
    let player: PlayerModel
    func makeNSView(context: Context) -> MTKView { player.renderer.makeView() }
    func updateNSView(_ nsView: MTKView, context: Context) { player.renderer.setNeedsDisplay() }
}

final class PanoramaRenderer: NSObject, MTKViewDelegate {
    private let device = MTLCreateSystemDefaultDevice()!
    private var commandQueue: MTLCommandQueue!
    private var pipeline: MTLRenderPipelineState!
    private var cache: CVMetalTextureCache!
    private weak var view: MTKView?
    private var leftTexture: MTLTexture?
    private var rightTexture: MTLTexture?
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var fov: Float = 1.42
    private var capture: CaptureReader?

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = self; view.colorPixelFormat = .bgra8Unorm; view.framebufferOnly = false; view.enableSetNeedsDisplay = true; view.isPaused = true
        commandQueue = device.makeCommandQueue()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let library = try! device.makeDefaultLibrary(bundle: .module)
        let descriptor = MTLRenderPipelineDescriptor(); descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex"); descriptor.fragmentFunction = library.makeFunction(name: "x5FisheyeFragment"); descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        let pan = NSPanGestureRecognizer(target: self, action: #selector(drag(_:))); view.addGestureRecognizer(pan)
        let zoom = NSMagnificationGestureRecognizer(target: self, action: #selector(magnify(_:))); view.addGestureRecognizer(zoom)
        self.view = view
        return view
    }

    func attach(capture: CaptureReader) { self.capture = capture; resetView() }
    func resetView() { yaw = 0; pitch = 0; fov = 1.42; setNeedsDisplay() }
    func seek(to seconds: Double) { capture?.seek(to: seconds); _ = presentNextFrame(from: capture) }
    func setNeedsDisplay() { view?.setNeedsDisplay(view?.bounds ?? .zero) }
    func presentNextFrame(from capture: CaptureReader?) -> Double? {
        guard let frame = capture?.nextFrame() else { return nil }
        leftTexture = texture(from: frame.left); rightTexture = texture(from: frame.right); setNeedsDisplay(); return frame.time
    }

    @objc private func drag(_ gesture: NSPanGestureRecognizer) {
        let t = gesture.translation(in: view); yaw -= Float(t.x) * 0.006; pitch = max(-1.3, min(1.3, pitch + Float(t.y) * 0.006)); gesture.setTranslation(.zero, in: view); setNeedsDisplay()
    }
    @objc private func magnify(_ gesture: NSMagnificationGestureRecognizer) { fov = max(0.62, min(2.25, fov - Float(gesture.magnification) * 0.35)); gesture.magnification = 0; setNeedsDisplay() }
    private func texture(from buffer: CVPixelBuffer) -> MTLTexture? {
        var textureRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .r8Unorm, CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &textureRef)
        return textureRef.flatMap(CVMetalTextureGetTexture)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let descriptor = view.currentRenderPassDescriptor, let queue = commandQueue else { return }
        let command = queue.makeCommandBuffer()!; let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)!; encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(leftTexture, index: 0); encoder.setFragmentTexture(rightTexture, index: 1)
        var uniforms = ViewUniforms(
            yaw: yaw,
            pitch: pitch,
            fov: fov,
            aspect: Float(view.drawableSize.width / max(view.drawableSize.height, 1)),
            hasFrame: leftTexture != nil && rightTexture != nil ? 1 : 0,
            padding: SIMD3<UInt32>(repeating: 0)
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding(); command.present(drawable); command.commit()
    }
}

private struct ViewUniforms {
    var yaw: Float
    var pitch: Float
    var fov: Float
    var aspect: Float
    var hasFrame: UInt32
    var padding: SIMD3<UInt32>
}
