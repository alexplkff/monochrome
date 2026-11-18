import CoreImage
import MetalKit

final class MetalPreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    let device: MTLDevice
    let engine: FilterEngine
    private let commandQueue: MTLCommandQueue
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var parameters: FilterParameters = .initialAA
    private var compare = false
    private var generation: UInt64 = 0
    private var drawnGeneration: UInt64 = .max

    init?(metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device = metalDevice, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.engine = FilterEngine(metalDevice: device)
        super.init()
    }

    func submit(_ buffer: CVPixelBuffer) {
        lock.lock()
        latestBuffer = buffer // Replace any unrendered frame; never accumulate a queue.
        generation &+= 1
        lock.unlock()
    }

    func update(parameters: FilterParameters, compare: Bool) {
        lock.lock()
        self.parameters = parameters
        self.compare = compare
        generation &+= 1
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let buffer = latestBuffer
        let settings = parameters
        let showsColor = compare
        let currentGeneration = generation
        lock.unlock()
        guard currentGeneration != drawnGeneration else { return }
        guard let buffer, let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let source = CIImage(cvPixelBuffer: buffer)
        let filtered = engine.apply(source, parameters: settings, compare: showsColor)
        let target = CGRect(origin: .zero, size: view.drawableSize)
        // Show the entire camera frame. Any unused area stays black instead of cropping the photo.
        let scale = min(target.width / filtered.extent.width, target.height / filtered.extent.height)
        let scaled = filtered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (target.width - scaled.extent.width) / 2 - scaled.extent.minX
        let y = (target.height - scaled.extent.height) / 2 - scaled.extent.minY
        let background = CIImage(color: .black).cropped(to: target)
        let output = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
            .composited(over: background)
        engine.context.render(output, to: drawable.texture, commandBuffer: commandBuffer,
                              bounds: target, colorSpace: engine.colorSpace)
        commandBuffer.addCompletedHandler { _ in _ = buffer }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        drawnGeneration = currentGeneration
    }
}
