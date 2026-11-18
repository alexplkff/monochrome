import SwiftUI

struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    if let renderer = model.renderer {
                        CameraPreviewView(renderer: renderer)
                            .frame(width: geometry.size.width,
                                   height: geometry.size.width * 4 / 3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Metal недоступен")
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        profileMenu
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .frame(height: 44)
                    exposureControl
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
                        .disabled(!model.cameraReady || model.isCapturing || model.isSwitchingLens)
                        .opacity(model.isCapturing ? 0.5 : 1)
                        .accessibilityLabel("Снять фото")
                        Spacer()
                        cameraMenu
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .frame(height: 104)
                }
                if model.editorVisible {
                    editor
                        .padding(.bottom, 210)
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

    private var profileMenu: some View {
        Menu {
            ForEach(model.presets) { preset in
                Button { model.select(preset.number) } label: {
                    if model.selectedNumber == preset.number {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
            Divider()
            if model.presets.count < 9 {
                Button("Создать профиль", systemImage: "plus") { model.createPreset() }
                Menu("Изменить номер") {
                    ForEach(model.presets.filter { $0.number != 0 }) { preset in
                        Menu(preset.label) {
                            ForEach((1...8).filter { candidate in
                                !model.presets.contains(where: { $0.number == candidate })
                            }, id: \.self) { number in
                                Button(String(number)) { model.rename(preset.number, to: number) }
                            }
                        }
                    }
                }
            }
            if model.presets.contains(where: { $0.number != 0 }) {
                Menu("Удалить профиль") {
                    ForEach(model.presets.filter { $0.number != 0 }) { preset in
                        Button(role: .destructive) { model.delete(preset.number) } label: {
                            Text(preset.label)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.presets.first(where: { $0.number == model.selectedNumber })?.label ?? "AA")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.65), in: Capsule())
        }
        .accessibilityLabel("Выбрать профиль")
    }

    private var exposureControl: some View {
        HStack(spacing: 12) {
            Text("EV")
            Slider(value: Binding(get: { model.exposureBias }, set: { model.updateExposure($0) }),
                   in: model.exposureRange)
                .tint(.white)
                .disabled(!model.cameraReady)
            Text(String(format: "%+.1f", model.exposureBias))
                .frame(width: 42, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.black.opacity(0.65), in: Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private var cameraMenu: some View {
        Menu {
            ForEach(model.availableLenses) { lens in
                Button { model.selectLens(lens) } label: {
                    if model.selectedLens == lens {
                        Label("\(lens.label) \(lens.name)", systemImage: "checkmark")
                    } else {
                        Text("\(lens.label) \(lens.name)")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.selectedLens.label)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 17, weight: .semibold, design: .monospaced))
            .frame(width: 64, height: 64)
        }
        .disabled(!model.cameraReady || model.isCapturing || model.isSwitchingLens)
        .accessibilityLabel("Выбрать камеру")
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
