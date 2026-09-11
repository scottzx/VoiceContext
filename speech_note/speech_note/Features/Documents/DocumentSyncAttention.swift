import Foundation
import Observation

/// User-visible sync attention for public documents / encrypted voiceprint mirrors.
/// LOCAL-FIRST invariant: these states never block microphone capture or local Documents writes.
nonisolated struct DocumentSyncAttention: Equatable, Sendable {
    enum Kind: String, Sendable, Equatable, CaseIterable {
        case conflict
        case insufficientSpace
        case networkInterrupted
        case accountUnavailable
        case ubiquityUnavailable
        case coordinationFailed
        case writeFailed
    }

    /// Product state token presented beside sync controls / export.
    static let needsAttentionState = "needs_attention"

    let kind: Kind
    /// Stable machine reason (e.g. `icloudAccountUnavailable`).
    let reasonCode: String
    let conflictRelativePaths: [String]
    let recordedAt: Date

    var state: String { Self.needsAttentionState }

    /// Failures must never block local recording.
    var blocksLocalRecording: Bool { false }

    var title: String {
        switch kind {
        case .conflict:
            "同步冲突，已保留双方副本"
        case .insufficientSpace:
            "iCloud 或磁盘空间不足"
        case .networkInterrupted:
            "同步网络中断"
        case .accountUnavailable:
            "未登录 iCloud"
        case .ubiquityUnavailable:
            "iCloud 容器不可用"
        case .coordinationFailed:
            "文件协调失败（可能被其他设备读取）"
        case .writeFailed:
            "同步写入失败"
        }
    }

    var message: String {
        switch kind {
        case .conflict:
            "公开文档冲突已保留副本，未静默覆盖任一方。本地 Documents 仍可读取与导出。"
        case .insufficientSpace:
            "空间不足，本次未完成云端镜像。录音与本地文稿不受影响；清理空间后可重试同步。"
        case .networkInterrupted:
            "网络中断导致同步未完成。本地录音、转写和导出仍可用。"
        case .accountUnavailable:
            "当前未登录 iCloud，已回退本机 VoiceContext。关闭或失败的同步不会阻塞录音。"
        case .ubiquityUnavailable:
            "iCloud Documents 容器不可用，已回退本机目录。可稍后在「我的」中重试。"
        case .coordinationFailed:
            "其他进程（例如 Mac 上的 Finder/Codex）正在读取文件。已使用原子替换，避免半文件；可稍后重试同步。"
        case .writeFailed:
            "同步写入失败，文档仍保存在本机。"
        }
    }

    init(
        kind: Kind,
        reasonCode: String,
        conflictRelativePaths: [String] = [],
        recordedAt: Date = Date()
    ) {
        self.kind = kind
        self.reasonCode = reasonCode
        self.conflictRelativePaths = conflictRelativePaths
        self.recordedAt = recordedAt
    }

    static func conflict(paths: [String], recordedAt: Date = Date()) -> DocumentSyncAttention {
        DocumentSyncAttention(
            kind: .conflict,
            reasonCode: "conflictCopiesPreserved",
            conflictRelativePaths: paths.sorted(),
            recordedAt: recordedAt
        )
    }

    static func fromFallbackReason(_ reason: String?, conflictPaths: [String] = []) -> DocumentSyncAttention? {
        guard let reason, !reason.isEmpty else { return nil }
        switch reason {
        case "documentSyncDisabled", "encryptedVoiceprintSyncDisabled",
             "incompleteDocument", "localEncryptedArchiveMissing":
            return nil
        case "icloudAccountUnavailable":
            return DocumentSyncAttention(kind: .accountUnavailable, reasonCode: reason)
        case "ubiquityContainerUnavailable":
            return DocumentSyncAttention(kind: .ubiquityUnavailable, reasonCode: reason)
        case "conflictCopiesPreserved":
            return conflict(paths: conflictPaths)
        case "insufficientSpace":
            return DocumentSyncAttention(kind: .insufficientSpace, reasonCode: reason)
        case "networkInterrupted":
            return DocumentSyncAttention(kind: .networkInterrupted, reasonCode: reason)
        case "coordinationFailed":
            return DocumentSyncAttention(
                kind: .coordinationFailed,
                reasonCode: reason,
                conflictRelativePaths: conflictPaths
            )
        default:
            return DocumentSyncAttention(kind: .writeFailed, reasonCode: reason, conflictRelativePaths: conflictPaths)
        }
    }

    /// Maps Foundation / POSIX write failures into attention kinds.
    static func classify(error: Error, conflictPaths: [String] = []) -> DocumentSyncAttention {
        if let fileIO = error as? PublicDocumentFileIO.FileIOError {
            switch fileIO {
            case .coordinationFailed:
                return DocumentSyncAttention(
                    kind: .coordinationFailed,
                    reasonCode: "coordinationFailed",
                    conflictRelativePaths: conflictPaths
                )
            case .escapedRoot:
                return DocumentSyncAttention(
                    kind: .writeFailed,
                    reasonCode: "escapedRoot",
                    conflictRelativePaths: conflictPaths
                )
            case .insufficientSpace:
                return DocumentSyncAttention(
                    kind: .insufficientSpace,
                    reasonCode: "insufficientSpace",
                    conflictRelativePaths: conflictPaths
                )
            case .networkInterrupted:
                return DocumentSyncAttention(
                    kind: .networkInterrupted,
                    reasonCode: "networkInterrupted",
                    conflictRelativePaths: conflictPaths
                )
            case .incompleteStaging:
                return DocumentSyncAttention(
                    kind: .writeFailed,
                    reasonCode: "incompleteStaging",
                    conflictRelativePaths: conflictPaths
                )
            }
        }

        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileWriteOutOfSpaceError {
                return DocumentSyncAttention(kind: .insufficientSpace, reasonCode: "insufficientSpace")
            }
            if ns.code == NSFileWriteVolumeReadOnlyError {
                return DocumentSyncAttention(kind: .writeFailed, reasonCode: "volumeReadOnly")
            }
        }
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed:
                return DocumentSyncAttention(kind: .networkInterrupted, reasonCode: "networkInterrupted")
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
            return DocumentSyncAttention(kind: .insufficientSpace, reasonCode: "insufficientSpace")
        }
        return DocumentSyncAttention(
            kind: .writeFailed,
            reasonCode: "writeFailed",
            conflictRelativePaths: conflictPaths
        )
    }
}

/// Main-actor store so Settings / Export can present `needs_attention` without
/// coupling sync failures to the recording pipeline.
@MainActor
@Observable
final class DocumentSyncStatusCenter {
    static let shared = DocumentSyncStatusCenter()

    private(set) var attention: DocumentSyncAttention?
    private(set) var lastPublicDestination: PublicDocumentMirrorResult.Destination?
    private(set) var lastVoiceprintDestination: EncryptedVoiceprintSyncResult.Destination?
    private(set) var lastFolderDestination: FolderSyncResult.Destination?

    var needsAttention: Bool { attention != nil }
    var stateToken: String? { attention?.state }

    func record(publicMirror result: PublicDocumentMirrorResult) {
        lastPublicDestination = result.destination
        if let attention = result.attention {
            self.attention = attention
        } else if result.destination == .localOnly,
                  let fallback = DocumentSyncAttention.fromFallbackReason(result.fallbackReason) {
            self.attention = fallback
        }
    }

    func record(voiceprint result: EncryptedVoiceprintSyncResult) {
        lastVoiceprintDestination = result.destination
        if let attention = result.attention {
            self.attention = attention
        } else if result.destination == .localOnly,
                  let fallback = DocumentSyncAttention.fromFallbackReason(result.fallbackReason) {
            self.attention = fallback
        }
    }


    func record(folder result: FolderSyncResult) {
        lastFolderDestination = result.destination
        if let attention = result.attention {
            self.attention = attention
        } else if result.destination == .localOnly,
                  let fallback = DocumentSyncAttention.fromFallbackReason(result.fallbackReason) {
            self.attention = fallback
        }
    }

    func record(_ attention: DocumentSyncAttention) {
        self.attention = attention
    }

    func clearAttention() {
        attention = nil
    }
}
