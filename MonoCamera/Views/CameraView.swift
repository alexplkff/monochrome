import SwiftUI

struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Text("MONO").font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Spacer()
                        Text("1×").font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 24).frame(height: 44)

                    if let renderer = model.renderer {
                        CameraPreviewView(renderer: renderer)
                            .aspectRatio(0.75, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        Text("Metal недоступен").foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    presetStrip
                        .frame(height: 62)

                    HStack {
                        Button { model.toggleEditor() } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 24, weight: .light))
                                .frame(width: 64, height: 64)
                        }
                        Spacer()
                        Button { model.shutter() } label: {
                            Circle().fill(.white)
                                .frame(width: 64, height: 64)
                                .overlay(Circle().stroke(.white, lineWidth: 2).frame(width: 76, height: 76))
                        }
                        .disabled(!model.cameraReady || model.isCapturing)
                        .opacity(model.isCapturing ? 0.5 : 1)
                        .accessibilityLabel("Снять фото")
                        Spacer()
                        Text(model.presets.first(where: { $0.number == model.selectedNumber })?.label ?? "AA")
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .frame(width: 64, height: 64)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .frame(height: 104)
                }
                if model.editorVisible {
                    editor
                        .padding(.bottom, 166)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else { model.stop() }
        }
        .alert("MonoCamera", isPresented: $model.showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
            ForEach(model.presets) { preset in
                Button { model.select(preset.number) } label: {
                    Text(preset.label)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(model.selectedNumber == preset.number ? .black : .white)
                        .frame(width: 42, height: 42)
                        .background(model.selectedNumber == preset.number ? .white : .white.opacity(0.16), in: Circle())
                }
                .contextMenu {
                    if preset.number != 0 {
                        ForEach((1...8).filter { candidate in
                            !model.presets.contains(where: { $0.number == candidate })
                        }, id: \.self) { number in
                            Button("Номер \(number)") { model.rename(preset.number, to: number) }
                        }
                        Button("Удалить", role: .destructive) { model.delete(preset.number) }
                    }
                }
            }
            if model.presets.count < 9 {
                Button { model.createPreset() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Создать профиль")
            }
            }
            .padding(.horizontal, 16)
            .frame(minWidth: 0)
        }
    }

    private var editor: some View {
        VStack(spacing: 8) {
            HStack {
                Text("ПРОФИЛЬ \(model.selectedNumber == 0 ? "AA" : String(model.selectedNumber))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Text("COMPARE")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(8)
                    .background(.white.opacity(0.15), in: Capsule())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in model.compare(true) }
                        .onEnded { _ in model.compare(false) })
                    .accessibilityLabel("Удерживайте для цветного изображения")
            }
            editorSlider("RED", value: model.draft.redWeight, range: 0...1) { model.updateWeight(0, value: $0) }
            editorSlider("GREEN", value: model.draft.greenWeight, range: 0...1) { model.updateWeight(1, value: $0) }
            editorSlider("BLUE", value: model.draft.blueWeight, range: 0...1) { model.updateWeight(2, value: $0) }
            editorSlider("CONTRAST", value: model.draft.contrast, range: -100...100) { model.updateContrast($0) }
            HStack {
                Button("Reset") { model.reset() }
                Spacer()
                Button("Cancel") { model.cancel() }
                Button("Save") { model.save() }.fontWeight(.semibold).padding(.leading, 20)
            }
            .font(.system(size: 14, design: .monospaced))
            .padding(.top, 8)
        }
        .padding(18)
        .foregroundStyle(.white)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
    }

    private func editorSlider(_ title: String, value: Float, range: ClosedRange<Float>,
                              change: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { value }, set: change), in: range)
                .tint(.white)
            Text(title == "CONTRAST" ? String(Int(value)) : String(format: "%.2f", value))
                .frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}
