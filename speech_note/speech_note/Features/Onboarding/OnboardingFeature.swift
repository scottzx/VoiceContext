import AVFAudio
import AVFoundation
import SwiftUI

/// The choices made during first launch. They are intentionally kept separate
/// from the eventual iCloud implementation: opting in must never make local
/// recording depend on a cloud account or network.
nonisolated struct OnboardingPreferences {
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

/// Shared microphone-boundary helpers for onboarding, settings, and start UX.
/// Permission prompts never start capture; only an explicit start action may.
///
/// Own enum avoids naming `AVAudioApplication.RecordPermission`, which does not
/// exist as a nested type on iPhoneOS 26.5 (`NS_SWIFT_NAME` imports it as the
/// awkward lowercase `AVAudioApplication.recordPermission`). Values are read
/// from `AVAudioApplication.shared.recordPermission` via pattern matching.
enum MicrophonePermission: Equatable, Sendable {
    case undetermined
    case denied
    case granted

    static var current: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }
}

enum MicrophoneAccess {
    typealias Permission = MicrophonePermission

    static var recordPermission: Permission { Permission.current }

    static var isDenied: Bool { recordPermission == .denied }
    static var isGranted: Bool { recordPermission == .granted }

    static let deniedBrowseMessage = "麦克风权限未允许。你仍可浏览已有记录和文稿。"
    static let deniedStartMessage = "未获得麦克风权限，无法开始录音。你仍可浏览记录；可在系统设置中允许麦克风。"
    static let undeterminedHint = "只有在你点按“开始录音”后才会采集麦克风。"

    static var settingsURL: URL {
        URL(string: UIApplication.openSettingsURLString)!
    }

    static func description(for permission: Permission) -> String {
        switch permission {
        case .granted: "已允许"
        case .denied: "未允许；仍可浏览记录"
        case .undetermined: "尚未请求"
        }
    }

    /// Requests the system permission prompt when undetermined. Never opens a
    /// capture session — callers must still wait for an explicit start action.
    @discardableResult
    static func requestPermissionIfNeeded() async -> Permission {
        let current = recordPermission
        if current != .undetermined { return current }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        return granted ? .granted : .denied
    }
}

/// Guideline 5.1.1(iv): after the educational microphone message, Continue
/// always proceeds to the system permission prompt. There is no Skip / Not Now
/// that delays the request. A later Continue after denial only advances setup.
enum OnboardingMicrophoneAdvance: Equatable, Sendable {
    /// Stay on the educational step so Settings is visible after a denial.
    case stayToShowSettings
    /// Leave the educational step; the system prompt already ran or is not needed.
    case advance

    static func action(
        permissionBefore: MicrophonePermission,
        permissionAfter: MicrophonePermission
    ) -> OnboardingMicrophoneAdvance {
        if permissionBefore == .undetermined {
            if permissionAfter == .denied { return .stayToShowSettings }
            return .advance
        }
        return .advance
    }

    static func shouldRequestSystemPrompt(_ permission: MicrophonePermission) -> Bool {
        permission == .undetermined
    }
}

struct OnboardingFlowView: View {
    @AppStorage(OnboardingPreferences.completedKey) private var hasCompleted = false
    @AppStorage(OnboardingPreferences.documentSyncKey) private var documentSyncEnabled = false
    @AppStorage(OnboardingPreferences.encryptedVoiceprintSyncKey) private var encryptedVoiceprintSyncEnabled = false
    @State private var step: OnboardingStep = .privacy
    @State private var microphonePermission = MicrophoneAccess.recordPermission
    @State private var isRequestingMicrophone = false

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
                #if VOICE_AGENT_FUSION
                OnboardingFact(symbol: "icloud", text: "录音同步不包含原始音频；智能体可同步你放入其工作区的文件。")
                OnboardingFact(symbol: "bubble.left.and.bubble.right", text: "使用在线模型时，聊天文字、引用文稿和你选择的附件会发送给所配置的模型服务。")
                #else
                OnboardingFact(symbol: "icloud", text: "iCloud 只可能同步文本和结构化文档，从不上传原始音频。")
                #endif
                OnboardingFact(symbol: "record.circle", text: "录音时始终显示状态和可独立操作的停止入口。")
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

            Text(TrialQuotaLedger.isManualTrialEnabled ? "第 1 步，共 3 步" : "第 1 步，共 2 步")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("让 VoiceContext 听见你主动开始的记录。")
                    .font(.title2.weight(.semibold))
                Text(MicrophoneAccess.undeterminedHint + " 你可以随时在系统设置中更改授权。")
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
                Text(MicrophoneAccess.deniedBrowseMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Link("前往系统设置", destination: MicrophoneAccess.settingsURL)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else if microphonePermission == .granted {
                Label("麦克风已允许", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            Button("继续") {
                Task { await continueFromMicrophoneStep() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .disabled(isRequestingMicrophone)
            .accessibilityHint(
                microphonePermission == .undetermined
                    ? "继续后将显示系统麦克风权限请求"
                    : "进入下一步，不会开始录音"
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .onAppear { microphonePermission = MicrophoneAccess.recordPermission }
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
                Text("公开文档与加密声纹同步相互独立。iCloud 不可用时，加密档案只保留在本机，不阻塞录音与转写。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(TrialQuotaLedger.isManualTrialEnabled ? "继续" : "开始使用") {
                if TrialQuotaLedger.isManualTrialEnabled {
                    step = .trial
                } else {
                    completeOnboarding()
                }
            }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityHint(
                    TrialQuotaLedger.isManualTrialEnabled
                        ? "继续了解试用"
                        : "进入记录页，不会自动开始录音"
                )
        }
    }

    private var trialStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 20)

            Text("第 3 步，共 3 步")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("首次打开后 3 天免费试用。")
                    .font(.title2.weight(.semibold))
                Text("试用自首次打开应用起连续计时 72 小时；试用期满后可一次性永久解锁。具体价格以 App Store 显示为准。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Label("试用到期后仍可录音和保存音频；转写会等待永久解锁。", systemImage: "lock.open")
                .font(.subheadline)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

            Spacer()

            Button("开始使用") { completeOnboarding() }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .accessibilityHint("进入记录页，不会自动开始录音")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private func continueFromMicrophoneStep() async {
        let before = microphonePermission
        if OnboardingMicrophoneAdvance.shouldRequestSystemPrompt(before) {
            isRequestingMicrophone = true
            microphonePermission = await MicrophoneAccess.requestPermissionIfNeeded()
            isRequestingMicrophone = false
        }
        if OnboardingMicrophoneAdvance.action(
            permissionBefore: before,
            permissionAfter: microphonePermission
        ) == .advance {
            step = .iCloud
        }
    }

    private func completeOnboarding() {
        hasCompleted = true
    }
}

struct PrivacyAndPermissionsView: View {
    @State private var microphonePermission = MicrophoneAccess.recordPermission
    @State private var locationPermission = LocationAccess.authorizationStatus
    @AppStorage("isAutoRecordLocationEnabled") private var isAutoRecordLocationEnabled = false

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
                    Text(MicrophoneAccess.description(for: microphonePermission))
                        .foregroundStyle(.secondary)
                }

                if microphonePermission == .denied {
                    Text(MicrophoneAccess.deniedBrowseMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("前往系统设置", destination: MicrophoneAccess.settingsURL)
                }

                Text("从「照片与视频」导入时，系统选择器只共享你选中的视频；应用会抽取音轨并在本地转写。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("麦克风权限")
            }

            Section {
                Toggle("录音时自动记录地点", isOn: $isAutoRecordLocationEnabled)
                    .onChange(of: isAutoRecordLocationEnabled) { _, enabled in
                        if enabled && locationPermission == .undetermined {
                            Task {
                                locationPermission = await LocationAccess.requestPermissionIfNeeded()
                            }
                        }
                    }

                LabeledContent("定位权限") {
                    Text(LocationAccess.description(for: locationPermission))
                        .foregroundStyle(.secondary)
                }

                if locationPermission == .denied {
                    Text(LocationAccess.deniedPromptMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("前往系统设置", destination: LocationAccess.settingsURL)
                } else if locationPermission == .undetermined {
                    Button("请求定位权限") {
                        Task {
                            locationPermission = await LocationAccess.requestPermissionIfNeeded()
                        }
                    }
                    .font(.subheadline)
                }

                Text("开启后，仅在录音时获取一次当前位置并转换为中文地址保存在录音元数据中。你可以随时在录音详情中编辑或清空该地址。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("位置与录音地点")
            }

            Section {
                Text("语音备忘录：在「语音备忘录」中分享/存储到「文件」，再回到 VoiceContext 用「导入 → 文件」选择该音频。v1 不提供 Share Extension。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("相册视频：首页「导入 → 照片与视频」选择视频；不设产品时长上限，长视频会抽取音轨后排队处理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("导入说明")
            } footer: {
                Text("不支持的格式会显示可读错误，且不会创建半残录音记录。")
            }

            Section {
                Label("公开 iCloud 文档不包含原始音频或明文声纹 embedding。", systemImage: "icloud")
                Label("长期声纹档案在同步前使用应用层 AES-GCM 加密。", systemImage: "lock.shield")
            } header: {
                Text("同步")
            }
        }
        .navigationTitle("隐私与权限")
        .onAppear {
            microphonePermission = MicrophoneAccess.recordPermission
            locationPermission = LocationAccess.authorizationStatus
        }
    }
}

struct ThirdPartyLicensesView: View {
    var body: some View {
        List {
            Section {
                Text("以下归因与审核清单内置在 App 中，可离线查看。外部许可链接仅用于查阅原始文本；不会影响本地录音和文稿。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("法律审核清单") {
                ForEach(LegalReviewChecklist.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title)
                                .font(.body.weight(.medium))
                            Spacer(minLength: 8)
                            Text(item.statusLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.status == .pendingLegalReview ? Color.orange : Color.secondary)
                        }
                        Text(item.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                if LegalReviewChecklist.blocksCommercialRelease {
                    Label("商业发布前须关闭全部“待法律审核”项。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            Section("第三方归因") {
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

enum LegalReviewStatus: String, Sendable {
    case recorded
    case pendingLegalReview
    case satisfied

    var label: String {
        switch self {
        case .recorded: "已记录"
        case .pendingLegalReview: "待法律审核"
        case .satisfied: "已满足"
        }
    }
}

struct LegalReviewChecklistItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let status: LegalReviewStatus
    let relatedAttributionName: String?

    var statusLabel: String { status.label }
}

enum LegalReviewChecklist {
    static let items: [LegalReviewChecklistItem] = [
        .init(
            id: "funasr-model-license",
            title: "SenseVoice / FunASR 模型商业许可",
            detail: "已完成 FunASR Model License 审核，允许商用；应用内已保留模型名称与作者出处归因。",
            status: .satisfied,
            relatedAttributionName: "SenseVoice Small / FunASR"
        ),
        .init(
            id: "transcribe-cpp-mit",
            title: "transcribe.cpp MIT 归因",
            detail: "发布包保留版权声明与 MIT 许可文本。",
            status: .satisfied,
            relatedAttributionName: "transcribe.cpp"
        ),
        .init(
            id: "sherpa-onnx-apache",
            title: "sherpa-onnx Apache 2.0 NOTICE",
            detail: "遵守 Apache 2.0 的 NOTICE 与归因要求。",
            status: .satisfied,
            relatedAttributionName: "sherpa-onnx"
        ),
        .init(
            id: "onnxruntime-mit",
            title: "ONNX Runtime MIT 归因",
            detail: "发布时保留版权与许可文本。",
            status: .satisfied,
            relatedAttributionName: "ONNX Runtime"
        ),
        .init(
            id: "silero-vad-mit",
            title: "Silero VAD MIT 归因",
            detail: "发布时保留版权与许可文本。",
            status: .satisfied,
            relatedAttributionName: "Silero VAD"
        ),
        .init(
            id: "camplusplus-license",
            title: "CAM++ / 3D-Speaker 许可复核",
            detail: "已完成 3D-Speaker / CAM++ 许可复核（Apache 2.0），允许商用；已保留版权与许可声明。",
            status: .satisfied,
            relatedAttributionName: "CAM++ / 3D-Speaker"
        ),
        .init(
            id: "offline-attribution-ui",
            title: "应用内离线归因页",
            detail: "设置页可离线浏览全部运行时与模型归因，不依赖网络。",
            status: .satisfied,
            relatedAttributionName: nil
        ),
        .init(
            id: "microphone-usage-copy",
            title: "麦克风用途说明",
            detail: "Info.plist NSMicrophoneUsageDescription 说明仅在用户主动开始后录音。",
            status: .satisfied,
            relatedAttributionName: nil
        ),
    ]

    static var blocksCommercialRelease: Bool {
        items.contains { $0.status == .pendingLegalReview }
    }

    static var attributionNamesCovered: Set<String> {
        Set(items.compactMap(\.relatedAttributionName))
    }
}

struct ThirdPartyAttribution: Identifiable, Hashable, Sendable {
    let name: String
    let summary: String
    let license: String
    let sourceURL: URL
    let licenseURL: URL
    let reviewStatus: String
    /// Short notice readable offline; not a substitute for the full license text.
    let offlineLicenseText: String

    var id: String { name }

    static let catalog: [ThirdPartyAttribution] = [
        .init(
            name: "SenseVoice Small / FunASR",
            summary: "端侧语音识别模型",
            license: "FunASR Model License",
            sourceURL: URL(string: "https://huggingface.co/FunAudioLLM/SenseVoiceSmall")!,
            licenseURL: URL(string: "https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE")!,
            reviewStatus: "已审核通过（FunASR Model License v1.1）：允许商用，须在发布中保留模型名称与作者出处。",
            offlineLicenseText: """
            FunASR Model License 明确允许自由使用、修改与分发（含商业用途）。VoiceContext 仅在设备本地离线推理 SenseVoice Small，并遵守协议保留作者出处与模型名称。完整条款见许可原文链接。
            """
        ),
        .init(
            name: "transcribe.cpp",
            summary: "本地转写运行时",
            license: "MIT License",
            sourceURL: URL(string: "https://github.com/handy-computer/transcribe.cpp")!,
            licenseURL: URL(string: "https://opensource.org/license/mit")!,
            reviewStatus: "已审核通过（MIT License）：允许商用，发布时保留版权与许可文本。",
            offlineLicenseText: """
            MIT License：在保留版权声明与许可声明的前提下，允许使用、复制、修改、合并、发布、分发、再许可和/或出售软件副本。软件按“原样”提供，不附带明示或暗示担保。
            """
        ),
        .init(
            name: "sherpa-onnx",
            summary: "端侧 VAD 与说话人运行时",
            license: "Apache License 2.0",
            sourceURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx")!,
            licenseURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE")!,
            reviewStatus: "已审核通过（Apache License 2.0）：允许商用，发布时须遵守 Apache 2.0 的 NOTICE 与归因要求。",
            offlineLicenseText: """
            Apache License 2.0：允许使用、修改与分发，条件包括保留版权、许可、NOTICE 声明，并说明对文件的重大修改。专利授权随贡献提供；商标权不授予。完整条款见许可原文。
            """
        ),
        .init(
            name: "ONNX Runtime",
            summary: "ONNX 推理运行时",
            license: "MIT License",
            sourceURL: URL(string: "https://github.com/microsoft/onnxruntime")!,
            licenseURL: URL(string: "https://github.com/microsoft/onnxruntime/blob/main/LICENSE")!,
            reviewStatus: "已审核通过（MIT License）：允许商用，发布时保留版权与许可文本。",
            offlineLicenseText: """
            MIT License：在保留版权声明与许可声明的前提下，允许使用、复制、修改、合并、发布、分发、再许可和/或出售软件副本。软件按“原样”提供，不附带明示或暗示担保。
            """
        ),
        .init(
            name: "Silero VAD",
            summary: "端侧语音活动检测模型",
            license: "MIT License",
            sourceURL: URL(string: "https://github.com/snakers4/silero-vad")!,
            licenseURL: URL(string: "https://github.com/snakers4/silero-vad/blob/master/LICENSE")!,
            reviewStatus: "已审核通过（MIT License）：允许商用，发布时保留版权与许可文本。",
            offlineLicenseText: """
            MIT License：在保留版权声明与许可声明的前提下，允许使用、复制、修改、合并、发布、分发、再许可和/或出售软件副本。软件按“原样”提供，不附带明示或暗示担保。
            """
        ),
        .init(
            name: "CAM++ / 3D-Speaker",
            summary: "端侧说话人 embedding 模型",
            license: "Apache License 2.0",
            sourceURL: URL(string: "https://github.com/modelscope/3D-Speaker")!,
            licenseURL: URL(string: "https://github.com/modelscope/3D-Speaker/blob/main/LICENSE")!,
            reviewStatus: "已审核通过（Apache License 2.0）：允许商用，发布时遵守 Apache 2.0 归因与 NOTICE 要求。",
            offlineLicenseText: """
            上游项目 3D-Speaker 及 CAM++ 模型遵循 Apache License 2.0。VoiceContext 仅在设备本地使用说话人 embedding，已满足许可归因与保留版权声明要求。完整条款见许可原文链接。
            """
        ),
        .init(
            name: "pyannote segmentation 3.0",
            summary: "端侧多人说话分段模型",
            license: "MIT License",
            sourceURL: URL(string: "https://huggingface.co/pyannote/segmentation-3.0")!,
            licenseURL: URL(string: "https://huggingface.co/pyannote/segmentation-3.0/blob/main/LICENSE")!,
            reviewStatus: "已核对随 sherpa-onnx 发布的转换模型内置 MIT 许可：允许商用，发布时保留 CNRS 版权与许可文本。",
            offlineLicenseText: """
            pyannote segmentation 3.0 模型采用 MIT License。VoiceContext 使用 sherpa-onnx 官方 release 中的 int8 ONNX 转换版，仅在设备本地执行说话分段，并在 App 包中保留完整许可文本。
            """
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

            Section("离线许可说明") {
                Text(attribution.offlineLicenseText.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
