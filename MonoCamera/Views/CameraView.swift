import SwiftUI
import UIKit
import PhotosUI

struct CameraView: View {
    @StateObject private var model = CameraViewModel()
    @State private var levelChannel: LevelChannel = .master
    @State private var exposurePhoto: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if let renderer = model.renderer {
                    CameraPreviewView(renderer: renderer)
                        .frame(width: geometry.size.width,
                               height: geometry.size.width * 4 / 3)
                    focusSurface(size: CGSize(width: geometry.size.width,
                                              height: geometry.size.width * 4 / 3))
                } else {
                    Text("Metal недоступен")
                        .foregroundStyle(.white)
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    captureModeControl
                    HStack {
                        profileMenu
                        Spacer()
                        if !model.exposureFailures.isEmpty {
                            Button("Повторить: \(model.exposureFailures.count)") { model.exposureControlsVisible = true }
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                        if model.pendingPhotoCount > 0 {
                            Text(model.isSaveQueueFull ? "Очередь заполнена" : "Сохранение: \(model.pendingPhotoCount)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                        }
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
                        .disabled(!model.canShutter || isLoadingPhoto)
                        .opacity(model.canShutter && !isLoadingPhoto ? 1 : 0.5)
                        .accessibilityLabel("Снять фото")
                        Spacer()
                        cameraMenu
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .frame(height: 104)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else { model.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.handleMemoryWarning()
        }
        .alert("MonoCamera", isPresented: $model.showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
        .sheet(isPresented: $model.editorVisible, onDismiss: { model.cancel() }) {
            editor
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $model.exposureControlsVisible) {
            doubleExposureEditor
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .task(id: exposurePhoto) {
            guard let item = exposurePhoto else { return }
            isLoadingPhoto = true
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CameraError.invalidPhoto }
                await model.importExposureFirst(data)
            } catch { model.reportImportError(error) }
            isLoadingPhoto = false
            exposurePhoto = nil
        }
    }

    private var captureModeControl: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Обычная съёмка", systemImage: "camera") { model.setExposureEnabled(false) }
                Button("Двойная экспозиция", systemImage: "square.on.square") { model.setExposureEnabled(true) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.exposureEnabled ? "square.on.square" : "camera")
                    Text(model.exposureEnabled ? "Двойная" : "Фото")
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
            }
            .disabled(model.isCapturing || model.isPreparingExposure || isLoadingPhoto)
            Spacer(minLength: 0)
            if model.exposureEnabled {
                Text(model.hasExposureFirst ? "Кадр 2/2" : "Кадр 1/2")
                    .foregroundStyle(.white.opacity(0.65))
                if !model.hasExposureFirst {
                    PhotosPicker(selection: $exposurePhoto, matching: .images) {
                        Image(systemName: "photo")
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("Первый кадр из Фото")
                    .disabled(model.isCapturing || model.isPreparingExposure || isLoadingPhoto)
                }
                Button { model.exposureControlsVisible = true } label: {
                    Image(systemName: "circle.lefthalf.filled").frame(width: 40, height: 40)
                }
                .accessibilityLabel("Настроить двойную экспозицию")
            }
            if isLoadingPhoto || model.isPreparingExposure { ProgressView().tint(.white) }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .frame(height: 40)
    }

    private var doubleExposureEditor: some View {
        VStack(spacing: 16) {
            HStack {
                Text("ДВОЙНАЯ ЭКСПОЗИЦИЯ")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Button("Готово") { model.exposureControlsVisible = false }
            }
            .padding(.top, 26)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.hasExposureFirst ? "Первый кадр готов. Следующий спуск сохранит композицию."
                         : "Снимите первый кадр или выберите его из Фото. Затем снимите второй.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    Picker("Смешивание", selection: Binding(get: { model.exposureSettings.mode }, set: { value in
                        model.updateExposureSettings { $0.mode = value }
                    })) {
                        ForEach(ExposureBlendMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    editorSlider("Сила наложения, %", value: model.exposureSettings.safeStrength, range: 0...100) { value in
                        model.updateExposureSettings { $0.strength = value }
                    }
                    editorSlider("Яркость первого", value: model.exposureSettings.firstBrightness, range: -3...3) { value in
                        model.updateExposureSettings { $0.firstBrightness = value }
                    }
                    editorSlider("Яркость второго", value: model.exposureSettings.secondBrightness, range: -3...3) { value in
                        model.updateExposureSettings { $0.secondBrightness = value }
                    }
                    if model.hasExposureFirst {
                        Button("Отменить пару", role: .destructive) { model.cancelExposurePair() }
                            .disabled(model.isCapturing || model.isPreparingExposure)
                    } else if model.exposureEnabled {
                        PhotosPicker("Первый кадр из Фото", selection: $exposurePhoto, matching: .images)
                            .disabled(model.isCapturing || model.isPreparingExposure || isLoadingPhoto)
                    }
                    if !model.exposureFailures.isEmpty {
                        Divider()
                        Text("НЕСОХРАНЁННЫЕ")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        ForEach(model.exposureFailures) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(record.lastError ?? "Не удалось записать композицию.")
                                    .font(.system(size: 12)).foregroundStyle(.orange)
                                Button(record.secondBytes > 0 ? "Повторить сохранение композиции" : "Повторить запись оригинала") {
                                    model.retryExposure(record.id)
                                }
                                .disabled(model.isCapturing || model.isPreparingExposure || model.isSaveQueueFull)
                                if record.stage == .failed {
                                    Button("Отменить композицию", role: .destructive) { model.discardExposureFailure(record.id) }
                                        .disabled(model.isPreparingExposure)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .padding(.horizontal, 20)
        .foregroundStyle(.white)
        .background(Color(white: 0.12))
    }

    private func focusSurface(size: CGSize) -> some View {
        FocusTouchView { location, lock in
            model.focus(at: location, previewSize: size, lock: lock)
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            ZStack(alignment: .top) {
                if let point = model.focusIndicatorPoint {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 74, height: 74)
                        .position(point)
                }
                if model.focusLocked {
                    Text("AE/AF LOCK")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(.top, 14)
                }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
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
                .disabled(!model.cameraReady || model.isSwitchingLens)
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
        VStack(spacing: 0) {
            HStack {
                Text("ПРОФИЛЬ \(model.selectedNumber == 0 ? "AA" : String(model.selectedNumber))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Button { model.shutter() } label: {
                    Image(systemName: "camera")
                }
                .disabled(!model.canShutter)
                .accessibilityLabel("Снять фото с текущими настройками")
                .padding(.trailing, 12)
                Button("Cancel") { model.cancel() }
                Button("Save") { model.save() }
                    .fontWeight(.semibold)
                    .padding(.leading, 12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 12) {
                    grainControls
                    Divider().padding(.vertical, 8)
                    HStack {
                        Text("УРОВНИ")
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
                    channelPicker
                    levelsGraph
                        .frame(height: 220)
                    levelHandles
                        .frame(height: 36)
                    HStack {
                        Text("ЧЁРНЫЙ")
                        Spacer()
                        Text("СРЕДНИЙ")
                        Spacer()
                        Text("БЕЛЫЙ")
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    Divider().padding(.vertical, 8)
                    editorSlider("RED", value: model.draft.redWeight, range: 0...1) { model.updateWeight(0, value: $0) }
                    editorSlider("GREEN", value: model.draft.greenWeight, range: 0...1) { model.updateWeight(1, value: $0) }
                    editorSlider("BLUE", value: model.draft.blueWeight, range: 0...1) { model.updateWeight(2, value: $0) }
                    editorSlider("CONTRAST", value: model.draft.contrast, range: -100...100) { model.updateContrast($0) }
                    Button("Reset") { model.reset() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.12))
    }

    private var grainControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ПЛЁНОЧНОЕ ЗЕРНО")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Picker("Марка зерна", selection: Binding(get: { model.draft.grain.brand },
                                                      set: { model.updateGrainBrand($0) })) {
                ForEach(GrainBrand.allCases) { brand in
                    Text(brand.label).tag(brand)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("ISO зерна")
                Spacer()
                Text(String(Int(model.draft.grain.safeISO.rounded())))
                    .monospacedDigit()
            }
            .font(.system(size: 13, design: .monospaced))
            Slider(value: Binding(get: { log2(model.draft.grain.safeISO / 50) },
                                  set: { model.updateGrainISO(50 * pow(2, $0)) }), in: 0...6)
                .tint(.white)
                .accessibilityLabel("ISO зерна")
                .accessibilityValue(String(Int(model.draft.grain.safeISO.rounded())))
            HStack {
                ForEach([50, 100, 200, 400, 800, 1600, 3200], id: \.self) { value in
                    Text(String(value))
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
            HStack {
                Text("Сила")
                Spacer()
                Text("\(Int(model.draft.grain.safeStrength.rounded()))%")
                    .monospacedDigit()
            }
            .font(.system(size: 13, design: .monospaced))
            Slider(value: Binding(get: { model.draft.grain.safeStrength },
                                  set: { model.updateGrainStrength($0) }), in: 0...100)
                .tint(.white)
                .accessibilityLabel("Сила зерна")
            Toggle("Предпросмотр зерна", isOn: Binding(get: { model.grainPreviewEnabled },
                                                       set: { model.setGrainPreview($0) }))
                .font(.system(size: 13))
                .tint(.white)
            Text("При силе выше 0% зерно сохраняется на фото, даже если предпросмотр выключен.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var channelPicker: some View {
        HStack(spacing: 18) {
            ForEach(LevelChannel.allCases) { channel in
                Button { levelChannel = channel } label: {
                    Circle()
                        .strokeBorder(channelColor(channel), lineWidth: levelChannel == channel ? 4 : 2)
                        .background(Circle().fill(levelChannel == channel ? channelColor(channel).opacity(0.25) : .clear))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel(channel.label)
            }
            Spacer()
        }
    }

    private var levelsGraph: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .color(Color(white: 0.16)))
            for index in 1..<4 {
                let x = size.width * CGFloat(index) / 4
                let y = size.height * CGFloat(index) / 4
                context.stroke(Path { path in
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }
            let bins = model.histogram[levelChannel.rawValue]
            var histogram = Path()
            histogram.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                histogram.addLine(to: CGPoint(x: size.width * CGFloat(index) / CGFloat(max(1, bins.count - 1)),
                                              y: size.height * (1 - CGFloat(value))))
            }
            histogram.addLine(to: CGPoint(x: size.width, y: size.height))
            histogram.closeSubpath()
            context.fill(histogram, with: .color(channelColor(levelChannel).opacity(0.25)))
            context.stroke(Path { path in
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: 0))
            }, with: .color(.white.opacity(0.35)), lineWidth: 1)
            let levels = model.draft.levels(for: levelChannel)
            var curve = Path()
            for index in 0...128 {
                let input = Float(index) / 128
                let point = CGPoint(x: size.width * CGFloat(input),
                                    y: size.height * (1 - CGFloat(levels.map(input))))
                if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(channelColor(levelChannel)), lineWidth: 2)
            context.stroke(Path(bounds), with: .color(.white.opacity(0.5)), lineWidth: 1)
        }
        .accessibilityLabel("Гистограмма и кривая уровней: \(levelChannel.label)")
    }

    private var levelHandles: some View {
        GeometryReader { geometry in
            let levels = model.draft.levels(for: levelChannel)
            let values = [levels.black, levels.middle, levels.white]
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(height: 3)
                    .position(x: geometry.size.width / 2, y: 18)
                ForEach(0..<3, id: \.self) { handle in
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(.black, lineWidth: 2))
                        .frame(width: 22, height: 22)
                        .position(x: 11 + CGFloat(values[handle]) * max(1, geometry.size.width - 22), y: 18)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("levelBar")).onChanged { gesture in
                            model.updateLevels(levelChannel, handle: handle,
                                               value: Float((gesture.location.x - 11) / max(1, geometry.size.width - 22)))
                        })
                        .accessibilityLabel(["Чёрная точка", "Средняя точка", "Белая точка"][handle])
                }
            }
            .coordinateSpace(name: "levelBar")
        }
    }

    private func channelColor(_ channel: LevelChannel) -> Color {
        switch channel {
        case .master: .white
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
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

private struct FocusTouchView: UIViewRepresentable {
    var onTouch: (CGPoint, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTouch: onTouch) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.55
        hold.allowableMovement = 20
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hold)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTouch = onTouch
    }

    final class Coordinator: NSObject {
        var onTouch: (CGPoint, Bool) -> Void

        init(onTouch: @escaping (CGPoint, Bool) -> Void) { self.onTouch = onTouch }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            onTouch(recognizer.location(in: view), false)
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            onTouch(recognizer.location(in: view), true)
        }
    }
}
