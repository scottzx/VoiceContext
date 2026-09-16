import SwiftUI

/// Popover / Sheet for comprehensive recording filtering (time, custom range, folder, origin).
struct RecordingFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: RecordingCoreModel
    @Binding var criteria: RecordingFilterCriteria

    @State private var draftCriteria: RecordingFilterCriteria

    init(model: RecordingCoreModel, criteria: Binding<RecordingFilterCriteria>) {
        self.model = model
        self._criteria = criteria
        self._draftCriteria = State(initialValue: criteria.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Section 1: Time Range
                Section("时间范围") {
                    Picker("时间范围", selection: $draftCriteria.timePreset) {
                        ForEach(RecordingTimePreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.title)).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    if draftCriteria.timePreset == .custom {
                        DatePicker(
                            "开始日期",
                            selection: $draftCriteria.customStartDate,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.compact)

                        DatePicker(
                            "结束日期",
                            selection: $draftCriteria.customEndDate,
                            in: draftCriteria.customStartDate...,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.compact)
                    }
                }

                // Section 2: Folder Category
                Section("文件夹分类") {
                    Picker("所属文件夹", selection: $draftCriteria.folderFilter) {
                        Text("全部文件夹").tag(RecordingFolderFilter.all)
                        Text("未分类").tag(RecordingFolderFilter.uncategorized)
                        if !model.folders.isEmpty {
                            Divider()
                            ForEach(model.folders) { folder in
                                Text(folder.name).tag(RecordingFolderFilter.folder(folder.id))
                            }
                        }
                    }
                }

                // Section 3: Recording Type
                Section("记录类型") {
                    Picker("记录类型", selection: $draftCriteria.originFilter) {
                        ForEach(RecordingOriginFilter.allCases) { origin in
                            Text(LocalizedStringKey(origin.title)).tag(origin)
                        }
                    }
                }

                // Section 4: Actions
                Section {
                    Button(role: .destructive) {
                        draftCriteria = RecordingFilterCriteria()
                    } label: {
                        HStack {
                            Spacer()
                            Text("重置所有筛选条件")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("筛选记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用筛选") {
                        criteria = draftCriteria
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
