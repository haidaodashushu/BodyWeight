import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct AddWeightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @StateObject private var speechService = SpeechRecognitionService()
    @State private var source: WeightEntry.Source = .manual
    @State private var weightText = ""
    @State private var selectedDate = Date()
    @State private var recognizedText = ""
    @State private var feedback = ""
    @State private var bodyPhotoPickerItem: PhotosPickerItem?
    @State private var bodyPhotoImage: UIImage?
    @State private var showsBodyCamera = false

    private let parser = WeightTextParser()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("录入方式", selection: $source) {
                        ForEach(WeightEntry.Source.availableInputCases, id: \.self) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                inputSection

                Section("确认记录") {
                    HStack {
                        TextField("例如 72.5", text: $weightText)
                            .keyboardType(.decimalPad)
                        Text("kg")
                            .foregroundStyle(.secondary)
                    }
                    DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
                }

                Section("当日全身照（可选）") {
                    Text("这张照片会与本条体重记录绑定，并同步到你的私人服务器。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let bodyPhotoImage {
                        Image(uiImage: bodyPhotoImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 320)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        showsBodyCamera = true
                    } label: {
                        Label("拍摄全身照", systemImage: "figure.stand")
                    }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                    PhotosPicker(selection: $bodyPhotoPickerItem, matching: .images) {
                        Label("从相册选择全身照", systemImage: "photo.on.rectangle")
                    }

                    if bodyPhotoImage != nil {
                        Button("移除这张照片", role: .destructive) {
                            bodyPhotoImage = nil
                            bodyPhotoPickerItem = nil
                        }
                    }
                }

                if !recognizedText.isEmpty || !feedback.isEmpty {
                    Section("识别结果") {
                        if !recognizedText.isEmpty {
                            Text(recognizedText)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        if !feedback.isEmpty {
                            Text(feedback)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("记录体重")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                }
            }
            .onChange(of: source) { _, newSource in
                feedback = ""
                if newSource != .voice { speechService.stop() }
            }
            .onChange(of: speechService.transcription) { _, text in
                recognizedText = text
                applyRecognizedText(text)
            }
            .onChange(of: bodyPhotoPickerItem) { _, item in
                guard let item else { return }
                Task { await loadBodyPhoto(item) }
            }
            .sheet(isPresented: $showsBodyCamera) {
                CameraPicker { image in
                    bodyPhotoImage = image
                }
                .ignoresSafeArea()
            }
            .onDisappear { speechService.stop() }
        }
    }

    @ViewBuilder
    private var inputSection: some View {
        switch source {
        case .manual, .photo:
            Section("手动输入") {
                Text("直接填写体重和日期；也可以输入“昨天 72.5kg”这样的句子。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("体重或一句话", text: $recognizedText)
                    .onSubmit { applyRecognizedText(recognizedText) }
                Button("识别这句话") { applyRecognizedText(recognizedText) }
            }

        case .voice:
            Section("语音输入") {
                Text("可以说：“今天的体重是 72.5 公斤”或“昨天 145 斤”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await toggleRecording() }
                } label: {
                    Label(
                        speechService.isRecording ? "停止并识别" : "开始说话",
                        systemImage: speechService.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                    )
                }
                .tint(speechService.isRecording ? .red : .accentColor)
            }
        }
    }

    private func applyRecognizedText(_ text: String) {
        guard let result = parser.parse(text) else {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                feedback = "还没有识别到有效体重，请确认数字和单位。"
            }
            return
        }
        weightText = result.weightKG.formatted(.number.precision(.fractionLength(0...2)))
        if result.dateWasExplicit { selectedDate = result.date }
        feedback = result.dateWasExplicit ? "已识别体重和日期，请确认后保存。" : "已识别体重；日期可手动调整。"
    }

    private func toggleRecording() async {
        if speechService.isRecording {
            speechService.stop()
            applyRecognizedText(speechService.transcription)
            return
        }
        do {
            try await speechService.start()
            feedback = "正在聆听…"
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func loadBodyPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw BodyPhotoStore.PhotoError.invalidImage
            }
            bodyPhotoImage = image
        } catch {
            feedback = "全身照读取失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        let normalized = weightText.replacingOccurrences(of: ",", with: ".")
        guard let weight = Double(normalized), (20...500).contains(weight) else {
            feedback = "请输入 20–500 kg 之间的有效体重。"
            return
        }

        let entry = WeightEntry(
            weightKG: weight,
            recordedAt: selectedDate,
            source: source,
            originalText: recognizedText
        )
        do {
            if let bodyPhotoImage {
                entry.photoLocalFilename = try BodyPhotoStore.save(bodyPhotoImage, for: entry.id)
                entry.photoUpdatedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            }
        } catch {
            feedback = "全身照保存失败：\(error.localizedDescription)"
            return
        }
        modelContext.insert(entry)
        do {
            try modelContext.save()
            Task { await WeightSyncService.shared.synchronize(modelContext: modelContext) }
            dismiss()
        } catch {
            feedback = "保存失败：\(error.localizedDescription)"
        }
    }
}
