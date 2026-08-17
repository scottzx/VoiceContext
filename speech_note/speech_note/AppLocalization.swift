import Foundation
import SwiftUI

/// Supported languages in VoiceContext.
enum AppLanguage: String, CaseIterable, Identifiable {
    case followSystem = "system"
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .followSystem: "跟随系统 / Follow System"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

/// Centralized localization manager for consistent language across the app.
@MainActor
final class AppLanguageCenter: ObservableObject {
    static let shared = AppLanguageCenter()

    @AppStorage("app_preferred_language") var selectedLanguage: AppLanguage = .followSystem

    var currentLocale: Locale {
        switch selectedLanguage {
        case .followSystem:
            return Locale.current
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }

    var isChinese: Bool {
        switch selectedLanguage {
        case .simplifiedChinese:
            return true
        case .english:
            return false
        case .followSystem:
            let lang = Locale.preferredLanguages.first ?? "zh-Hans"
            return lang.hasPrefix("zh")
        }
    }

    func text(_ key: AppStringKey) -> String {
        isChinese ? key.zh : key.en
    }
}

/// Canonical string dictionary to avoid mixed languages or technical jargon.
enum AppStringKey {
    // Navigation & Main
    case appName
    case recordingsTitle
    case searchPlaceholder
    case filterButton
    case filterActive
    case clearSearch
    case searchResultsCount(Int)
    case searchNoResults
    case searchNoResultsHint
    case emptyRecordingsTitle
    case emptyRecordingsDescription

    // Top Workstation & Tools
    case workstationMenu
    case clientManagement
    case importAudioFile
    case importPhotosVideo
    case newFolder
    case manageFolders
    case allFolders
    case uncategorized
    case folderFilter(String)

    // Capture & Recording
    case startRecording
    case recordingInProgress
    case minimize
    case directStart
    case retryStart
    case recordingTitle
    case isMeetingToggle
    case meetingTitlePlaceholder
    case optionalInfo
    case micOccupiedHint
    case selectParticipants

    // Detail & Player
    case recordingDetail
    case meetingDetail
    case editTranscript
    case saveEdits
    case saving
    case audioSection
    case audioUnavailable
    case skipBack15
    case skipForward15
    case play
    case pause
    case playbackRate
    case transcriptTab
    case speakersTab
    case detailsTab
    case exportTab
    case speakerCurrent
    case copySentence
    case copiedToClipboard
    case bindToClient
    case createClientFromSpeaker

    // Clients
    case clientsTitle
    case newClient
    case editClient
    case clientName
    case clientOrganization
    case clientRole
    case clientContact
    case clientNotes
    case clientTags
    case voiceprintStatus
    case voiceprintEnrolled(Int)
    case voiceprintNotEnrolled
    case deleteClient
    case saveClient

    // Filter
    case filterTitle
    case timeRange
    case timeAll
    case timeToday
    case timeLastSevenDays
    case timeThisMonth
    case timeCustom
    case startDate
    case endDate
    case categoryFolder
    case recordType
    case typeAll
    case typeMicrophone
    case typeMeeting
    case typeImported
    case resetFilter
    case applyFilter

    // Status & System
    case statusReady
    case statusTranscribing
    case statusNeedsAttention
    case statusLocked
    case revision(Int)
    case settings
    case languageSetting
    case cancel
    case done
    case confirm
    case delete

    var zh: String {
        switch self {
        case .appName: "语音便签"
        case .recordingsTitle: "全部录音"
        case .searchPlaceholder: "搜索转写内容与标签…"
        case .filterButton: "筛选"
        case .filterActive: "已筛选"
        case .clearSearch: "清除搜索"
        case .searchResultsCount(let n): "\(n) 条结果"
        case .searchNoResults: "没有找到相关转写"
        case .searchNoResultsHint: "试试其他关键词，或清空搜索查看全部记录。"
        case .emptyRecordingsTitle: "暂无录音记录"
        case .emptyRecordingsDescription: "轻点底部麦克风开始录音，或从顶部导入音频与视频。"

        case .workstationMenu: "工作台与导入"
        case .clientManagement: "客户档案与声纹"
        case .importAudioFile: "导入音频文件…"
        case .importPhotosVideo: "导入相册视频…"
        case .newFolder: "新建文件夹…"
        case .manageFolders: "管理文件夹…"
        case .allFolders: "全部文件夹"
        case .uncategorized: "未分类"
        case .folderFilter(let name): "文件夹：\(name)"

        case .startRecording: "开始录音"
        case .recordingInProgress: "录音进行中"
        case .minimize: "最小化"
        case .directStart: "直接开始录音"
        case .retryStart: "重试开始录音"
        case .recordingTitle: "录音标题"
        case .isMeetingToggle: "这是一次会议"
        case .meetingTitlePlaceholder: "例：产品周会 / 客户洽谈"
        case .optionalInfo: "基本信息"
        case .micOccupiedHint: "当前麦克风正在录音，请先停止"
        case .selectParticipants: "预选参会客户"

        case .recordingDetail: "录音详情"
        case .meetingDetail: "会议详情"
        case .editTranscript: "编辑"
        case .saveEdits: "保存"
        case .saving: "保存中…"
        case .audioSection: "音频播放"
        case .audioUnavailable: "音频暂不可用"
        case .skipBack15: "快退 15 秒"
        case .skipForward15: "快进 15 秒"
        case .play: "播放"
        case .pause: "暂停"
        case .playbackRate: "倍速"
        case .transcriptTab: "逐字稿"
        case .speakersTab: "参会人与声纹"
        case .detailsTab: "详细信息"
        case .exportTab: "导出与分享"
        case .speakerCurrent: "发言中"
        case .copySentence: "复制文本"
        case .copiedToClipboard: "已复制到剪贴板"
        case .bindToClient: "关联客户档案"
        case .createClientFromSpeaker: "保存为新客户"

        case .clientsTitle: "客户档案"
        case .newClient: "新建客户"
        case .editClient: "编辑客户"
        case .clientName: "姓名"
        case .clientOrganization: "公司 / 组织"
        case .clientRole: "职位 / 头衔"
        case .clientContact: "联系方式"
        case .clientNotes: "备注"
        case .clientTags: "标签（用逗号分隔）"
        case .voiceprintStatus: "声纹档案"
        case .voiceprintEnrolled(let count): "已采集 \(count) 个声纹特征向量"
        case .voiceprintNotEnrolled: "未采集声纹样本"
        case .deleteClient: "删除客户"
        case .saveClient: "保存客户档案"

        case .filterTitle: "筛选记录"
        case .timeRange: "时间范围"
        case .timeAll: "全部时间"
        case .timeToday: "今天"
        case .timeLastSevenDays: "最近 7 天"
        case .timeThisMonth: "本月"
        case .timeCustom: "自定义时间"
        case .startDate: "开始日期"
        case .endDate: "结束日期"
        case .categoryFolder: "所属文件夹"
        case .recordType: "记录类型"
        case .typeAll: "全部类型"
        case .typeMicrophone: "个人录音"
        case .typeMeeting: "会议记录"
        case .typeImported: "导入文件与视频"
        case .resetFilter: "重置"
        case .applyFilter: "应用筛选"

        case .statusReady: "已就绪"
        case .statusTranscribing: "转写中"
        case .statusNeedsAttention: "需要注意"
        case .statusLocked: "等待解锁"
        case .revision(let n): "版本 \(n)"
        case .settings: "设置与偏好"
        case .languageSetting: "界面语言"
        case .cancel: "取消"
        case .done: "完成"
        case .confirm: "确认"
        case .delete: "删除"
        }
    }

    var en: String {
        switch self {
        case .appName: "VoiceContext"
        case .recordingsTitle: "All Recordings"
        case .searchPlaceholder: "Search transcripts & tags…"
        case .filterButton: "Filter"
        case .filterActive: "Filtered"
        case .clearSearch: "Clear Search"
        case .searchResultsCount(let n): "\(n) results"
        case .searchNoResults: "No matching transcripts found"
        case .searchNoResultsHint: "Try different keywords or clear search to view all recordings."
        case .emptyRecordingsTitle: "No Recordings Yet"
        case .emptyRecordingsDescription: "Tap the mic at the bottom to start recording, or import files from the top menu."

        case .workstationMenu: "Workstation & Import"
        case .clientManagement: "Client Profiles & Voiceprints"
        case .importAudioFile: "Import Audio File…"
        case .importPhotosVideo: "Import Photos & Video…"
        case .newFolder: "New Folder…"
        case .manageFolders: "Manage Folders…"
        case .allFolders: "All Folders"
        case .uncategorized: "Uncategorized"
        case .folderFilter(let name): "Folder: \(name)"

        case .startRecording: "Start Recording"
        case .recordingInProgress: "Recording in Progress"
        case .minimize: "Minimize"
        case .directStart: "Start Recording Directly"
        case .retryStart: "Retry Recording"
        case .recordingTitle: "Title"
        case .isMeetingToggle: "This is a meeting"
        case .meetingTitlePlaceholder: "e.g. Weekly Sync / Client Meeting"
        case .optionalInfo: "Basic Info"
        case .micOccupiedHint: "Microphone is in use, please stop current session first"
        case .selectParticipants: "Select Participants"

        case .recordingDetail: "Recording Detail"
        case .meetingDetail: "Meeting Detail"
        case .editTranscript: "Edit"
        case .saveEdits: "Save"
        case .saving: "Saving…"
        case .audioSection: "Audio Player"
        case .audioUnavailable: "Audio Unavailable"
        case .skipBack15: "Back 15s"
        case .skipForward15: "Forward 15s"
        case .play: "Play"
        case .pause: "Pause"
        case .playbackRate: "Speed"
        case .transcriptTab: "Transcript"
        case .speakersTab: "Speakers"
        case .detailsTab: "Details"
        case .exportTab: "Export & Share"
        case .speakerCurrent: "Speaking"
        case .copySentence: "Copy Text"
        case .copiedToClipboard: "Copied to clipboard"
        case .bindToClient: "Link to Client Profile"
        case .createClientFromSpeaker: "Create as New Client"

        case .clientsTitle: "Client Profiles"
        case .newClient: "New Client"
        case .editClient: "Edit Client"
        case .clientName: "Name"
        case .clientOrganization: "Company / Organization"
        case .clientRole: "Role / Title"
        case .clientContact: "Contact Info"
        case .clientNotes: "Notes"
        case .clientTags: "Tags (comma separated)"
        case .voiceprintStatus: "Voiceprint Profile"
        case .voiceprintEnrolled(let count): "\(count) voice vectors enrolled"
        case .voiceprintNotEnrolled: "No voiceprint samples enrolled"
        case .deleteClient: "Delete Client"
        case .saveClient: "Save Client"

        case .filterTitle: "Filter Recordings"
        case .timeRange: "Time Range"
        case .timeAll: "All Time"
        case .timeToday: "Today"
        case .timeLastSevenDays: "Last 7 Days"
        case .timeThisMonth: "This Month"
        case .timeCustom: "Custom Date Range"
        case .startDate: "Start Date"
        case .endDate: "End Date"
        case .categoryFolder: "Folder"
        case .recordType: "Recording Type"
        case .typeAll: "All Types"
        case .typeMicrophone: "Voice Note"
        case .typeMeeting: "Meeting"
        case .typeImported: "Imported Audio/Video"
        case .resetFilter: "Reset"
        case .applyFilter: "Apply Filter"

        case .statusReady: "Ready"
        case .statusTranscribing: "Transcribing"
        case .statusNeedsAttention: "Attention Needed"
        case .statusLocked: "Pending Unlock"
        case .revision(let n): "Revision \(n)"
        case .settings: "Settings & Preferences"
        case .languageSetting: "Language"
        case .cancel: "Cancel"
        case .done: "Done"
        case .confirm: "Confirm"
        case .delete: "Delete"
        }
    }
}

/// Helper extension for easy localized string lookup.
extension String {
    static func appLocalized(_ key: AppStringKey) -> String {
        AppLanguageCenter.shared.text(key)
    }
}
