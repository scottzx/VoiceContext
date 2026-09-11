import Foundation

typealias RecordingFolderFilter = FolderListFilter

/// Time range filter mode for recordings.
enum RecordingTimePreset: String, CaseIterable, Identifiable, Equatable {
    case all
    case today
    case lastSevenDays
    case thisMonth
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部时间"
        case .today: "今天"
        case .lastSevenDays: "最近 7 天"
        case .thisMonth: "本月"
        case .custom: "自定义时间"
        }
    }
}

/// Recording type/origin filter.
enum RecordingOriginFilter: String, CaseIterable, Identifiable, Equatable {
    case all
    case microphone
    case meeting
    case imported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部类型"
        case .microphone: "个人录音"
        case .meeting: "会议记录"
        case .imported: "导入音视频"
        }
    }
}

/// Structured filter criteria for recording list.
struct RecordingFilterCriteria: Equatable {
    var timePreset: RecordingTimePreset = .all
    var customStartDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    var customEndDate: Date = Date()
    var folderFilter: RecordingFolderFilter = .all
    var originFilter: RecordingOriginFilter = .all

    var isFiltered: Bool {
        timePreset != .all || folderFilter != .all || originFilter != .all
    }

    var activeFilterSummaryCount: Int {
        var count = 0
        if timePreset != .all { count += 1 }
        if folderFilter != .all { count += 1 }
        if originFilter != .all { count += 1 }
        return count
    }

    func matches(
        recording: Recording,
        folderID: UUID?,
        calendar: Calendar = .current
    ) -> Bool {
        // 1. Time matching
        if !matchesTime(recording.startedAt, calendar: calendar) {
            return false
        }

        // 2. Folder matching
        switch folderFilter {
        case .all:
            break
        case .uncategorized:
            if folderID != nil { return false }
        case .folder(let id):
            if folderID != id { return false }
        }

        // 3. Origin matching
        switch originFilter {
        case .all:
            break
        case .microphone:
            if recording.origin == .importedAudio || recording.isMeeting { return false }
        case .meeting:
            if !recording.isMeeting { return false }
        case .imported:
            if recording.origin != .importedAudio { return false }
        }

        return true
    }

    private func matchesTime(_ date: Date, calendar: Calendar) -> Bool {
        let now = Date()
        switch timePreset {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .lastSevenDays:
            guard let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else {
                return false
            }
            return date >= start
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .custom:
            let startOfDay = calendar.startOfDay(for: customStartDate)
            let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: customEndDate) ?? customEndDate
            return date >= startOfDay && date <= endOfDay
        }
    }
}
