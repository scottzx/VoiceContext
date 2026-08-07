import AVFAudio
import SwiftUI

/// The choices made during first launch. They are intentionally kept separate
/// from the eventual iCloud implementation: opting in must never make local
/// recording depend on a cloud account or network.
struct OnboardingPreferences {
    static let completedKey = "onboarding.completed"
    static let documentSyncKey = "onboarding.documentSyncEnabled"
    static let encryptedVoiceprintSyncKey = "onboarding.encryptedVoiceprintSyncEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasCompleted: Bool {
        get { defaults.bool(forKey: Self.completedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.completedKey) }
    }

    var documentSyncEnabled: Bool {
        get { defaults.bool(forKey: Self.documentSyncKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.documentSyncKey) }
    }

    var encryptedVoiceprintSyncEnabled: Bool {
        get { defaults.bool(forKey: Self.encryptedVoiceprintSyncKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.encryptedVoiceprintSyncKey) }
    }
}

enum OnboardingStep: Int, CaseIterable {
    case privacy
    case microphone
    case iCloud
    case trial
}

struct OnboardingFlowView: View {
    @AppStorage(OnboardingPreferences.completedKey) private var hasCompleted = false
    @AppStorage(OnboardingPreferences.documentSyncKey) private var documentSyncEnabled = false
    @AppStorage(OnboardingPreferences.encryptedVoiceprintSyncKey) private var encryptedVoiceprintSyncEnabled = false
    @State private var step: OnboardingStep = .privacy
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .privacy:
                    localPrivacyStep
                case .microphone:
                    microphoneStep
                case .iCloud:
                    iCloudStep
                case .trial:
                    trialStep
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .privacy {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回") { step = previousStep }
                    }
                }
            }
        }
    }

    private var title: String {
        switch step {
        case .privacy: "欢迎"
        case .microphone: "麦克风权限"
        case .iCloud: "同步选择"
        case .trial: "免费试用"
        }
    }

    private var previousStep: OnboardingStep {
        OnboardingStep(rawValue: step.rawValue - 1) ?? .privacy
    }

    private var localPrivacyStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 20)

            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .regular))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text("把一个念头，留在你的设备上。")
                    .font(.title.weight(.bold))
                Text("个人灵感、现场对话或一场会议，都从同一个“开始录音”进入。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                OnboardingFact(symbol: "lock", text: "录音、转写和说话人处理在设备本地完成。")
                OnboardingFact(symbol: "calendar", text: "原始音频默认保留 7 天；你可逐条选择长期保留。")
                OnboardingFact(symbol: "icloud", text: "iCloud 只可能同步文本和结构化文档，从不上传原始音频。")
            }

            Spacer()

            Button("继续") { step = .microphone }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .frame(maxWidth: .infinity, minHeight: 52)

            Button("暂时跳过") { completeOnboarding() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityHint("不会请求麦克风，也不会开始录音")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 20)

            Text("第 1 步，共 3 步")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("让 VoiceContext 听见你主动开始的记录。")
                    .font(.title2.weight(.semibold))
                Text("只有在你点按“开始录音”后才会采集麦克风。你可以随时在系统设置中更改授权。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Label {
                Text("拒绝权限后，你仍可浏览已有记录和文稿。")
            } icon: {
                Image(systemName: "lock")
                    .foregroundStyle(.blue)
            }
            .font(.subheadline)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

            Spacer()

            if microphonePermission == .denied {
                Text("麦克风权限尚未允许。你可以继续浏览，或前往系统设置授权。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Link("前往系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else if microphonePermission == .granted {
                Label("麦克风已允许", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Button("允许麦克风") { requestMicrophonePermission() }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }

            if microphonePermission == .granted {
                Button("继续") { step = .iCloud }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                Button("暂不允许") { step = .iCloud }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .onAppear { microphonePermission = AVAudioApplication.shared.recordPermission }
    }

    private var iCloudStep: some View {
        Form {
            Section {
                Text("同步是可选的。关闭 iCloud 后，录音、转写、编辑和导出仍完整保留在本机。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Section("公开文档") {
                Toggle("同步 Markdown 与 JSON 文档", isOn: $documentSyncEnabled)
                Text("只同步完成后的文本与结构化文档；原始音频从不进入公开 iCloud Drive。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("加密声纹档案") {
                Toggle("同步加密的已确认声纹档案", isOn: $encryptedVoiceprintSyncEnabled)
                Text("仅同步用户确认过的档案，并在同步前进行应用层加密。未经确认的声纹不会同步。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("当前版本会保存你的选择；同步功能可用后才会按此选择工作。iCloud 不可用时，文档仍保存在本机。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("继续") { step = .trial }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    private var trialStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 20)

            Text("第 3 步，共 3 步")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("60 分钟免费本地转写。")
                    .font(.title2.weight(.semibold))
                Text("额度按实际提交给 SenseVoice 的语音时长计算；静音、暂停和未提交模型的录音不计入。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Label("额度用尽后仍可录音和保存音频；转写会等待永久解锁。", systemImage: "lock.open")
                .font(.subheadline)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

            Spacer()

            Button("开始使用") { completeOnboarding() }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                microphonePermission = granted ? .granted : .denied
            }
        }
    }

    private func completeOnboarding() {
        hasCompleted = true
    }
}

struct PrivacyAndPermissionsView: View {
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission

    var body: some View {
        List {
            Section {
                Text("VoiceContext 不会自动监听。只有在你明确点按“开始录音”后，才会访问麦克风。")
            } header: {
                Text("录音边界")
            }

            Section {
                Label("录音、转写和说话人处理均在设备本地完成。", systemImage: "iphone")
                Label("原始音频只保存在录制设备上，默认保留 7 天。", systemImage: "lock")
                Label("录音时始终显示状态和可独立操作的停止入口。", systemImage: "record.circle")
                Label("不会录制电话或其他 App 的系统音频。", systemImage: "hand.raised")
            } header: {
                Text("本地处理")
            }

            Section {
                LabeledContent("麦克风") {
                    Text(permissionDescription)
                        .foregroundStyle(.secondary)
                }

                if microphonePermission == .denied {
                    Link("前往系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
            } header: {
                Text("权限")
            }

            Section {
                Label("公开 iCloud 文档不包含原始音频或明文声纹 embedding。", systemImage: "icloud")
                Label("长期声纹档案在同步前使用应用层 AES-GCM 加密。", systemImage: "lock.shield")
            } header: {
                Text("同步")
            }
        }
        .navigationTitle("隐私与权限")
        .onAppear { microphonePermission = AVAudioApplication.shared.recordPermission }
    }

    private var permissionDescription: String {
        switch microphonePermission {
        case .granted: "已允许"
        case .denied: "未允许；仍可浏览记录"
        case .undetermined: "尚未请求"
        @unknown default: "状态未知"
        }
    }
}

struct ThirdPartyLicensesView: View {
    var body: some View {
        List {
            Section {
                Text("以下归因内置在 App 中，可离线查看。外部许可链接仅用于查阅原始文本；不会影响本地录音和文稿。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(ThirdPartyAttribution.catalog) { attribution in
                NavigationLink {
                    ThirdPartyLicenseDetailView(attribution: attribution)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attribution.name)
                            .font(.body.weight(.medium))
                        Text(attribution.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("发布前审核") {
                Label("SenseVoice / FunASR 模型商业许可仍需法律审核后才能发布。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("第三方许可与归因")
    }
}

private struct OnboardingFact: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).font(.body)
        } icon: {
            Image(systemName: symbol)
                .frame(width: 24)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ThirdPartyAttribution: Identifiable, Hashable, Sendable {
    let name: String
    let summary: String
    let license: String
    let sourceURL: URL
    let licenseURL: URL
    let reviewStatus: String

    var id: String { name }

    static let catalog: [ThirdPartyAttribution] = [
        .init(
            name: "SenseVoice Small / FunASR",
            summary: "端侧语音识别模型",
            license: "FunASR Model License",
            sourceURL: URL(string: "https://huggingface.co/FunAudioLLM/SenseVoiceSmall")!,
            licenseURL: URL(string: "https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE")!,
            reviewStatus: "商业发布前须完成 FunASR 模型许可法律审核。"
        ),
        .init(
            name: "transcribe.cpp",
            summary: "本地转写运行时",
            license: "MIT License",
            sourceURL: URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
            licenseURL: URL(string: "https://opensource.org/license/mit")!,
            reviewStatus: "已记录为 MIT 许可；发布时保留版权与许可文本。"
        ),
        .init(
            name: "sherpa-onnx",
            summary: "端侧 VAD 与说话人运行时",
            license: "Apache License 2.0",
            sourceURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx")!,
            licenseURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE")!,
            reviewStatus: "发布时须遵守 Apache 2.0 的 NOTICE 与归因要求。"
        ),
        .init(
            name: "ONNX Runtime",
            summary: "ONNX 推理运行时",
            license: "MIT License",
            sourceURL: URL(string: "https://github.com/microsoft/onnxruntime")!,
            licenseURL: URL(string: "https://github.com/microsoft/onnxruntime/blob/main/LICENSE")!,
            reviewStatus: "已记录为 MIT 许可；发布时保留版权与许可文本。"
        ),
        .init(
            name: "Silero VAD",
            summary: "端侧语音活动检测模型",
            license: "MIT License",
            sourceURL: URL(string: "https://github.com/snakers4/silero-vad")!,
            licenseURL: URL(string: "https://github.com/snakers4/silero-vad/blob/master/LICENSE")!,
            reviewStatus: "已记录为 MIT 许可；发布时保留版权与许可文本。"
        ),
        .init(
            name: "CAM++ / 3D-Speaker",
            summary: "端侧说话人 embedding 模型",
            license: "项目 LICENSE（发布前复核）",
            sourceURL: URL(string: "https://github.com/modelscope/3D-Speaker")!,
            licenseURL: URL(string: "https://github.com/modelscope/3D-Speaker/blob/main/LICENSE")!,
            reviewStatus: "发布前应由法务复核模型与上游依赖的适用许可。"
        ),
    ]
}

private struct ThirdPartyLicenseDetailView: View {
    let attribution: ThirdPartyAttribution

    var body: some View {
        List {
            Section("归因") {
                LabeledContent("用途", value: attribution.summary)
                LabeledContent("许可", value: attribution.license)
            }

            Section("审核状态") {
                Text(attribution.reviewStatus)
            }

            Section("原始资料") {
                Link("查看项目来源", destination: attribution.sourceURL)
                Link("查看许可原文", destination: attribution.licenseURL)
            }
        }
        .navigationTitle(attribution.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
