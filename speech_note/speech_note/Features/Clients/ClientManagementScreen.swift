import SwiftUI

/// Screen to view, search, add, and manage client profiles & voiceprint associations.
struct ClientManagementScreen: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel

    @State private var searchQuery = ""
    @State private var selectedTag: String? = nil
    @State private var isCreatingClient = false
    @State private var editingClient: ClientProfile? = nil
    @State private var deleteTargetClient: ClientProfile? = nil
    @State private var voiceprintArchive: VoiceprintArchive? = nil
    @State private var errorMessage: String? = nil

    private var filteredClients: [ClientProfile] {
        var list = model.clients
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list = list.filter { client in
                client.name.localizedCaseInsensitiveContains(trimmed)
                    || client.organization.localizedCaseInsensitiveContains(trimmed)
                    || client.roleOrTitle.localizedCaseInsensitiveContains(trimmed)
                    || client.notes.localizedCaseInsensitiveContains(trimmed)
                    || client.tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
            }
        }
        if let selectedTag {
            list = list.filter { $0.tags.contains(selectedTag) }
        }
        return list
    }

    private var allTags: [String] {
        let set = Set(model.clients.flatMap(\.tags))
        return set.sorted()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索客户姓名、公司、标签…", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Tag filter strip
                if !allTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button {
                                selectedTag = nil
                            } label: {
                                Text("全部标签")
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selectedTag == nil ? Color.primary : Color(uiColor: .secondarySystemBackground))
                                    .foregroundStyle(selectedTag == nil ? Color(uiColor: .systemBackground) : Color.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            ForEach(allTags, id: \.self) { tag in
                                Button {
                                    selectedTag = (selectedTag == tag) ? nil : tag
                                } label: {
                                    Text(tag)
                                        .font(.subheadline)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(selectedTag == tag ? Color.primary : Color(uiColor: .secondarySystemBackground))
                                        .foregroundStyle(selectedTag == tag ? Color(uiColor: .systemBackground) : Color.primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                }

                if filteredClients.isEmpty {
                    ContentUnavailableView {
                        Label(
                            model.clients.isEmpty ? "暂无客户档案" : "未找到匹配客户",
                            systemImage: "person.2"
                        )
                    } description: {
                        Text(
                            model.clients.isEmpty
                                ? "录入客户信息并关联声纹，在会议录音与转写时自动识别说话人身份。"
                                : "尝试使用其他关键词或清除标签筛选。"
                        )
                    } actions: {
                        if model.clients.isEmpty {
                            Button {
                                isCreatingClient = true
                            } label: {
                                Label("新建客户档案", systemImage: "plus")
                                    .font(.body.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredClients) { client in
                            clientRow(client)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteTargetClient = client
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    Button {
                                        editingClient = client
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("客户档案与声纹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreatingClient = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建客户档案")
                }
            }
            .sheet(isPresented: $isCreatingClient) {
                ClientEditSheet(model: model, existingClient: nil) { newClient in
                    Task {
                        await model.upsertClient(newClient)
                    }
                }
            }
            .sheet(item: $editingClient) { client in
                ClientEditSheet(model: model, existingClient: client) { updatedClient in
                    Task {
                        await model.upsertClient(updatedClient)
                    }
                }
            }
            .confirmationDialog(
                "确定删除客户「\(deleteTargetClient?.name ?? "")」？",
                isPresented: Binding(
                    get: { deleteTargetClient != nil },
                    set: { if !$0 { deleteTargetClient = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let client = deleteTargetClient {
                        Task {
                            await model.deleteClient(id: client.id)
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后不会影响已有录音与文稿内容。")
            }
            .task {
                await loadArchive()
            }
        }
    }

    @ViewBuilder
    private func clientRow(_ client: ClientProfile) -> some View {
        let voiceVectorsCount = voiceprintVectorCount(for: client)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // Avatar circle with initials
                ZStack {
                    Circle()
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .frame(width: 44, height: 44)
                    Text(String(client.name.prefix(2)))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(client.name)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if voiceVectorsCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform.badge.checkmark")
                                    .font(.caption2)
                                Text("已录入声纹 (\(voiceVectorsCount))")
                                    .font(.caption2.weight(.medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .foregroundStyle(Color.green)
                            .clipShape(Capsule())
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform.slash")
                                    .font(.caption2)
                                Text("待采集声纹")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                        }
                    }

                    if !client.displaySubtitle.isEmpty {
                        Text(client.displaySubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    editingClient = client
                } label: {
                    Image(systemName: "pencil.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if !client.phoneOrEmail.isEmpty || !client.tags.isEmpty || !client.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !client.phoneOrEmail.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "envelope.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(client.phoneOrEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !client.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(client.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(uiColor: .tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }

                    if !client.notes.isEmpty {
                        Text(client.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 54)
            }
        }
        .padding(.vertical, 4)
    }

    private func voiceprintVectorCount(for client: ClientProfile) -> Int {
        guard let voiceprintID = client.voiceprintIdentityID,
              let identity = voiceprintArchive?.identity(id: voiceprintID) else {
            return 0
        }
        return identity.embeddings.count
    }

    private func loadArchive() async {
        do {
            let url = try VoiceprintArchiveStorage.defaultURL()
            voiceprintArchive = try VoiceprintArchiveStorage.load(from: url)
        } catch {
            voiceprintArchive = nil
        }
    }
}

/// Sheet to create or edit a client profile.
struct ClientEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    let existingClient: ClientProfile?
    var onSave: (ClientProfile) -> Void

    @State private var name: String = ""
    @State private var organization: String = ""
    @State private var roleOrTitle: String = ""
    @State private var phoneOrEmail: String = ""
    @State private var notes: String = ""
    @State private var tagsText: String = ""
    @State private var voiceprintIdentityID: UUID? = nil
    @State private var availableIdentities: [VoiceprintIdentity] = []
    @State private var validationError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section("基本信息") {
                    TextField("姓名（必填）", text: $name)
                    TextField("公司 / 组织", text: $organization)
                    TextField("职位 / 角色", text: $roleOrTitle)
                    TextField("联系方式（手机或邮箱）", text: $phoneOrEmail)
                }

                Section("标签与备注") {
                    TextField("标签（用逗号或空格分隔）", text: $tagsText)
                    TextField("备注信息", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("声纹特征库绑定") {
                    if availableIdentities.isEmpty {
                        Text("当前尚未采集到声纹特征样本。在录音详情的「参会人」中确认说话人后，即可将声纹样本自动或手动关联至此客户。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("关联声纹特征", selection: $voiceprintIdentityID) {
                            Text("暂不关联声纹").tag(UUID?.none)
                            ForEach(availableIdentities, id: \.id) { identity in
                                Text("\(identity.displayName) (\(identity.embeddings.count) 条采样)").tag(UUID?.some(identity.id))
                            }
                        }
                        Text("关联后，在会议录音进行离线聚类与识别时，系统将通过声纹特征自动识别此客户。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(existingClient == nil ? "新建客户档案" : "编辑客户档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let existing = existingClient {
                    name = existing.name
                    organization = existing.organization
                    roleOrTitle = existing.roleOrTitle
                    phoneOrEmail = existing.phoneOrEmail
                    notes = existing.notes
                    tagsText = existing.tags.joined(separator: ", ")
                    voiceprintIdentityID = existing.voiceprintIdentityID
                }
                loadIdentities()
            }
        }
    }

    private func loadIdentities() {
        do {
            let url = try VoiceprintArchiveStorage.defaultURL()
            let archive = try VoiceprintArchiveStorage.load(from: url)
            availableIdentities = archive.identities
        } catch {
            availableIdentities = []
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationError = "客户姓名不能为空"
            return
        }

        let parsedTags = tagsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let client = ClientProfile(
            id: existingClient?.id ?? UUID(),
            name: trimmedName,
            organization: organization,
            roleOrTitle: roleOrTitle,
            phoneOrEmail: phoneOrEmail,
            notes: notes,
            tags: parsedTags,
            voiceprintIdentityID: voiceprintIdentityID,
            createdAt: existingClient?.createdAt ?? Date(),
            updatedAt: Date()
        )

        onSave(client)
        dismiss()
    }
}
