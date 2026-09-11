import SwiftUI

/// Small dedicated confirm / deny / rename surface for VCSpeakerIdentity.
/// Kept out of ContentView so parallel UI work is not blocked.
struct SpeakerIdentityConfirmView: View {
    let binding: MeetingSpeakerBinding
    var onConfirm: (String) -> Void
    var onDeny: () -> Void
    var onRename: (String) -> Void

    @State private var draftName: String = ""
    @State private var isRenaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(binding.chipText)
            } icon: {
                Image(systemName: iconName)
            }
            .foregroundStyle(foregroundStyle)
            .accessibilityLabel(accessibilityLabel)

            HStack(spacing: 12) {
                if binding.state.isSuspected || binding.state == .unknown {
                    Button("确认") {
                        onConfirm(resolvedDraftName)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(!canConfirmToArchive)
                    .accessibilityLabel("确认说话人")
                    .accessibilityHint(
                        canConfirmToArchive
                            ? "将当前名称写入长期声纹档案"
                            : "暂无可用声纹，无法写入档案；请先重命名做本场标记"
                    )

                    if binding.state.isSuspected {
                        Button("否认", role: .destructive, action: onDeny)
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityLabel("否认疑似说话人")
                            .accessibilityHint("清除疑似匹配，保持未知")
                    }
                }

                Button(isRenaming ? "保存名称" : "重命名") {
                    if isRenaming {
                        onRename(resolvedDraftName)
                        isRenaming = false
                    } else {
                        draftName = binding.state.linkedDisplayName
                            ?? binding.meetingAlias
                            ?? ""
                        isRenaming = true
                    }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityLabel(isRenaming ? "保存说话人显示名称" : "重命名说话人")
            }

            if !canConfirmToArchive, binding.state.isSuspected || binding.state == .unknown {
                Text("暂无可用声纹样本。可用「重命名」做本场标记；离线聚类完成后才能确认到声纹档案。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("speaker-no-embedding-hint")
            }

            if isRenaming {
                TextField("显示名称", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("说话人显示名称")
            }
        }
        .padding(.vertical, 4)
    }

    private var canConfirmToArchive: Bool {
        !binding.candidateEmbeddings.isEmpty
    }

    private var resolvedDraftName: String {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return binding.state.linkedDisplayName
            ?? binding.meetingAlias
            ?? binding.temporaryLabel
    }

    private var iconName: String {
        switch binding.state {
        case .unknown:
            "person.crop.circle.badge.questionmark"
        case .suspected:
            "person.crop.circle.badge.exclamationmark"
        case .confirmed:
            "person.crop.circle.badge.checkmark"
        }
    }

    private var foregroundStyle: AnyShapeStyle {
        switch binding.state {
        case .unknown:
            AnyShapeStyle(.primary)
        case .suspected:
            AnyShapeStyle(Color(red: 1, green: 0.624, blue: 0.039)) // vc.warning
        case .confirmed:
            AnyShapeStyle(.primary)
        }
    }

    private var accessibilityLabel: String {
        switch binding.state {
        case .unknown:
            "未知说话人 \(binding.chipText)"
        case .suspected:
            "疑似说话人 \(binding.state.linkedDisplayName ?? "")"
        case .confirmed:
            "已确认说话人 \(binding.state.linkedDisplayName ?? "")"
        }
    }
}

#Preview("suspected") {
    SpeakerIdentityConfirmView(
        binding: MeetingSpeakerBinding(
            temporaryLabel: "说话人 1",
            state: .suspected(identityID: UUID(), displayName: "Alice")
        ),
        onConfirm: { _ in },
        onDeny: {},
        onRename: { _ in }
    )
    .padding()
}
