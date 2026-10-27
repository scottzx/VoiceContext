import SwiftUI

/// Compact remote state above the unchanged native composer.
struct DSHConversationControls: View {
    @ObservedObject var vm: AIChatViewModel
    var onHeightChange: (CGFloat) -> Void
    @State private var presentedInteraction: DSHInteraction?

    private var showsControls: Bool {
        vm.isLoadingSession || !vm.dshConnected || vm.isProcessing
            || vm.dshHasMore || !vm.dshInteractions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsControls {
                Divider()
                HStack(spacing: YimaDesign.Space.sm) {
                    Text(vm.dshStatusText.isEmpty ? AppLocalized("正在连接…") : vm.dshStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if vm.dshHasMore {
                        Button("更早消息") { vm.loadOlderDSHMessages() }
                            .font(.caption)
                            .frame(minHeight: YimaDesign.Layout.hitTarget)
                            .disabled(vm.dshControlBusy || !vm.dshConnected)
                    }
                    if let interaction = vm.dshInteractions.first {
                        Button("处理请求") { presentedInteraction = interaction }
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: YimaDesign.Layout.hitTarget)
                            .disabled(vm.dshControlBusy || !vm.dshConnected)
                            .accessibilityHint(interaction.title)
                    } else if !vm.dshConnected && !vm.isLoadingSession && vm.hasCompletedInitialLoad {
                        Button("重新连接") { Task { await vm.loadDSHSession() } }
                            .font(.subheadline)
                            .frame(minHeight: YimaDesign.Layout.hitTarget)
                    }
                }
                .padding(.horizontal, YimaDesign.Layout.listInset)
                .padding(.vertical, YimaDesign.Space.xs)
            }
        }
        .background(YimaDesign.Color.canvas)
        .accessibilityIdentifier("dshConversationControls")
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChange(height)
        }
        .sheet(item: $presentedInteraction) { interaction in
            NavigationStack {
                DSHInteractionView(vm: vm, interaction: interaction)
            }
        }
    }
}

struct DSHModelPickerView: View {
    @ObservedObject var vm: AIChatViewModel
    @State private var selectedID: String?
    @State private var reasoningEffort = ""
    @Environment(\.dismiss) private var dismiss

    private var usesACP: Bool { vm.dshAgentPreset?.hasPrefix("oneagents-acp-") == true }
    private var selectedModel: DSHModelOption? {
        vm.dshModels.first { $0.id == selectedID }
    }

    var body: some View {
        Form {
            if let error = vm.errorMessage {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            if usesACP {
                DSHACPConfigurationSections(vm: vm)
            } else if vm.dshModels.isEmpty {
                Section {
                    Text("远程服务尚未提供可选模型。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("模型") {
                    ForEach(vm.dshModels) { model in
                        Button {
                            selectedID = model.id
                            reasoningEffort = ""
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name.isEmpty ? model.model : model.name)
                                        .foregroundStyle(.primary)
                                    Text(model.provider)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedID == model.id { Image(systemName: "checkmark") }
                            }
                            .frame(minHeight: YimaDesign.Layout.hitTarget)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let model = selectedModel, !model.reasoningEfforts.isEmpty {
                    Section("推理强度") {
                        Picker("推理强度", selection: $reasoningEffort) {
                            Text("服务默认").tag("")
                            ForEach(model.reasoningEfforts, id: \.self) { effort in
                                Text(effort).tag(effort)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("远程模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    if usesACP { dismiss(); return }
                    if let model = selectedModel {
                        Task {
                            if await vm.selectDSHModel(model, reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort) { dismiss() }
                        }
                    }
                }
                .disabled(vm.dshControlBusy || (!usesACP && (selectedModel == nil || !vm.dshConnected || vm.isProcessing)))
            }
        }
        .onAppear {
            if let current = vm.dshModelSelection {
                selectedID = current.provider + "/" + current.model
                reasoningEffort = current.reasoningEffort ?? ""
            }
        }
        .task {
            if usesACP { await vm.loadDSHACPConfiguration() }
        }
        .tint(YimaDesign.Color.ink)
        .appFontScale()
    }
}

private struct DSHACPConfigurationSections: View {
    @ObservedObject var vm: AIChatViewModel

    private var writable: Bool {
        vm.dshACPConfiguration["writable"] as? Bool == true
            && vm.dshConnected && !vm.dshControlBusy && !vm.isProcessing
    }

    var body: some View {
        Group {
            if vm.dshACPConfiguration.isEmpty {
                Section { Text(vm.dshControlBusy ? AppLocalized("正在读取远程配置…") : AppLocalized("远程服务未提供可编辑配置。")).foregroundStyle(.secondary) }
            } else {
                if vm.dshACPConfiguration["blocked"] as? String == "active-writer" {
                    Section { Text("此会话正在其他客户端操作，配置暂时只读。").foregroundStyle(.secondary) }
                }
                ForEach(Array(DSHWire.array(vm.dshACPConfiguration["configOptions"]).enumerated()), id: \.offset) { _, option in
                    configurationOption(option)
                }
                let modes = DSHWire.object(vm.dshACPConfiguration["modes"])
                let choices = DSHWire.array(modes["availableModes"])
                if let current = modes["currentModeId"] as? String, !choices.isEmpty {
                    Section("运行模式") {
                        Picker("运行模式", selection: Binding(
                            get: { current },
                            set: { value in Task { _ = await vm.setDSHACPConfiguration(configID: "$mode", value: value) } }
                        )) {
                            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                                if let id = choice["id"] as? String {
                                    Text(choice["name"] as? String ?? id).tag(id)
                                }
                            }
                        }
                        .disabled(!writable)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func configurationOption(_ option: [String: Any]) -> some View {
        let name = option["name"] as? String ?? option["id"] as? String ?? AppLocalized("远程选项")
        Section(name) {
            if let id = option["id"] as? String,
               option["type"] as? String == "select",
               let current = option["currentValue"] as? String {
                let choices = flattenedChoices(option["options"])
                if !choices.isEmpty {
                    Picker(name, selection: Binding(
                        get: { current },
                        set: { value in Task { _ = await vm.setDSHACPConfiguration(configID: id, value: value) } }
                    )) {
                        if !choices.contains(where: { $0["value"] as? String == current }) {
                            Text("\(current)（当前值）").tag(current)
                        }
                        ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                            if let value = choice["value"] as? String {
                                Text(choice["name"] as? String ?? value).tag(value)
                            }
                        }
                    }
                    .disabled(!writable)
                } else {
                    Text(current).foregroundStyle(.secondary)
                }
            } else {
                Text("服务尚未声明可编辑的选项。").foregroundStyle(.secondary)
            }
        }
    }

    private func flattenedChoices(_ value: Any?) -> [[String: Any]] {
        DSHWire.array(value).flatMap { option in
            if option["group"] != nil {
                return DSHWire.array(option["options"])
            }
            return [option]
        }.filter { $0["value"] is String }
    }
}

private struct DSHInteractionView: View {
    @ObservedObject var vm: AIChatViewModel
    let interaction: DSHInteraction
    @State private var selections: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private var isCurrent: Bool {
        vm.dshConnected && vm.dshInteractions.contains { $0.id == interaction.id }
    }

    private var allQuestionsAnswered: Bool {
        interaction.questions.allSatisfy {
            !(selections[$0.id] ?? []).isEmpty
                || !(customAnswers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        Form {
            Section {
                Text(interaction.title).font(.headline)
                if !interaction.detail.isEmpty {
                    Text(interaction.detail).font(.body)
                }
                if let error = vm.errorMessage { Text(error).foregroundStyle(.secondary) }
                if !isCurrent {
                    Text("此请求已失效或连接正在恢复，请返回后处理最新请求。")
                        .foregroundStyle(.secondary)
                }
            }
            if interaction.kind == .approval {
                Section {
                    Button("允许这次操作") {
                        Task { if await vm.respondToDSHApproval(interaction, allow: true) { dismiss() } }
                    }
                    Button("拒绝", role: .destructive) {
                        Task { if await vm.respondToDSHApproval(interaction, allow: false) { dismiss() } }
                    }
                }
                .disabled(!isCurrent || vm.dshControlBusy)
            } else {
                ForEach(interaction.questions) { question in
                    Section {
                        Text(question.prompt).font(.headline)
                        if !question.detail.isEmpty {
                            Text(question.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(question.options) { option in
                            Button {
                                var selected = selections[question.id] ?? []
                                if selected.contains(option.label) { selected.remove(option.label) }
                                else if question.allowsMultiple { selected.insert(option.label) }
                                else { selected = [option.label] }
                                selections[question.id] = selected
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(option.label).foregroundStyle(.primary)
                                        if !option.detail.isEmpty {
                                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selections[question.id]?.contains(option.label) == true {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .frame(minHeight: YimaDesign.Layout.hitTarget)
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("补充回答", text: Binding(
                            get: { customAnswers[question.id] ?? "" },
                            set: { customAnswers[question.id] = $0 }
                        ), axis: .vertical)
                    }
                    .disabled(!isCurrent || vm.dshControlBusy)
                }
                Section {
                    Button("提交回答") {
                        let answers = interaction.questions.map { question in
                            DSHQuestionAnswer(id: question.id,
                                              selected: question.options.map(\.label).filter { selections[question.id]?.contains($0) == true },
                                              custom: customAnswers[question.id])
                        }
                        Task { if await vm.respondToDSHQuestions(interaction, answers: answers) { dismiss() } }
                    }
                    .disabled(!isCurrent || vm.dshControlBusy || !allQuestionsAnswered)
                }
            }
        }
        .navigationTitle(interaction.kind == .approval ? AppLocalized("远程操作确认") : AppLocalized("远程问题"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } }
        }
        .tint(YimaDesign.Color.ink)
        .appFontScale()
    }
}

/// Remote tools expose output and copy only; no local terminal or browser pool.
struct DSHReadOnlyToolSheet: View {
    @ObservedObject var block: AssistantBlock
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var input: String? {
        guard let value = block.toolInputArgs?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return Self.formattedJSON(value) ?? value
    }

    private var shellCommand: String? {
        guard case .shellTool = block.kind,
              let data = block.toolInputArgs?.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = args["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return command
    }

    private var fileOutput: DSHFileReadOutput? {
        guard case .fileReadTool = block.kind else { return nil }
        return DSHFileReadOutput.parse(block.content)
    }

    private var resultContent: String { fileOutput?.content ?? block.content }

    private var usesMarkdown: Bool {
        switch block.kind {
        case .fileReadTool(let path):
            if fileOutput == nil, block.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<path>") {
                return false
            }
            let filePath = fileOutput?.path ?? path
            return ["md", "markdown"].contains((filePath as NSString).pathExtension.lowercased())
        case .shellTool, .fileWriteTool, .fileEditTool: return false
        default: return true
        }
    }

    private var resultMarkdown: String {
        if let json = Self.formattedJSON(resultContent) { return "```json\n" + json + "\n```" }
        return AIChatViewModel.dshDisplayText(resultContent)
    }

    private var emptyResult: String {
        switch block.toolStatus {
        case .success: return AppLocalized("工具已完成，没有输出。")
        case .failed(let message): return message
        case .cancelled: return AppLocalized("已取消")
        case .running, .streaming: return AppLocalized("等待远程工具输出…")
        case nil: return AppLocalized("执行结果未确认")
        }
    }

    @ViewBuilder
    private var resultView: some View {
        if usesMarkdown || Self.formattedJSON(resultContent) != nil {
            let markdown = resultMarkdown
            SelectableMarkdownView(
                markdown: markdown,
                cachedContent: MarkdownContent(prepareMarkdownForRender(markdown)),
                blockId: block.id
            )
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(resultContent)
                .font(.system(size: FontSettings.shared.scaledMessage(YimaDesign.Typography.bodySize), design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shellResultView(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ShellToolTextContent(
                command: sanitizeForDisplay(command),
                chunks: ShellToolTextContent.chunkedLines(block.content),
                fontSize: FontSettings.shared.scaledMessage(13),
                commandColor: YimaDesign.Color.ink,
                outputColor: YimaDesign.Color.ink
            )
            if block.content.isEmpty {
                Text(emptyResult).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
        }
        .textSelection(.enabled)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YimaDesign.Color.grouped)
        .clipShape(RoundedRectangle(cornerRadius: YimaDesign.Radius.control))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YimaDesign.Layout.sectionGap) {
                    if let command = shellCommand {
                        shellResultView(command)
                    }
                    if let input {
                        DisclosureGroup(shellCommand == nil ? AppLocalized("输入") : AppLocalized("原始参数")) {
                            Text(input)
                                .font(.system(size: FontSettings.shared.scaledMessage(YimaDesign.Typography.bodySize), design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(YimaDesign.Typography.section)
                        .frame(minHeight: YimaDesign.Layout.hitTarget)
                    }
                    if shellCommand == nil {
                        VStack(alignment: .leading, spacing: YimaDesign.Space.sm) {
                            Text("结果").font(YimaDesign.Typography.section)
                            if resultContent.isEmpty {
                                Text(emptyResult).font(.body).foregroundStyle(.secondary)
                            } else {
                                resultView
                            }
                            if let notices = fileOutput?.notices {
                                Text(notices).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(YimaDesign.Layout.listInset)
            }
            .navigationTitle(block.toolSummary ?? block.toolDescription)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "已复制" : "复制") {
                        UIPasteboard.general.string = [input, block.content.isEmpty ? nil : block.content]
                            .compactMap { $0 }.joined(separator: "\n\n")
                        copied = true
                    }
                    .disabled(input == nil && block.content.isEmpty)
                }
            }
        }
        .tint(YimaDesign.Color.ink)
        .appFontScale()
        .environment(\.chatSessionId, nil)
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }

    private static func formattedJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: formatted, encoding: .utf8)
    }
}
