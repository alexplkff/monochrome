import MetalKit
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let renderer: MetalPreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
