import Foundation
import CryptoKit

/// ASR 离线模型元信息定义
public struct ASRModelInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let fileName: String
    public let description: String
    public let approximateSizeMB: Int
    public let languages: [String]
    public let expectedSHA256: String?
    public let downloadURL: String?

    public init(
        id: String,
        name: String,
        fileName: String,
        description: String,
        approximateSizeMB: Int,
        languages: [String],
        expectedSHA256: String? = nil,
        downloadURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.description = description
        self.approximateSizeMB = approximateSizeMB
        self.languages = languages
        self.expectedSHA256 = expectedSHA256
        self.downloadURL = downloadURL
    }
}

/// 统一 ASR 离线模型注册与多层级寻址中心
public enum ModelRegistry {
    /// 默认内置推荐模型：SenseVoiceSmall (241MB, 中英粤日韩极速转写)
    public static let senseVoice = ASRModelInfo(
        id: "sensevoice-small-q8",
        name: "SenseVoice Small (推荐)",
        fileName: "SenseVoiceSmall-Q8_0.gguf",
        description: "极速且高准确率，精通中/英/粤/日/韩五语，单次最优窗口约30秒，适合日常对话、输入法与视频口播",
        approximateSizeMB: 241,
        languages: ["zh", "en", "yue", "ja", "ko"],
        expectedSHA256: "6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29",
        downloadURL: "https://modelscope.cn/api/v1/models/scott887/SenseVoiceSmall-Q8_0.gguf/repo?Revision=master&FilePath=SenseVoiceSmall-Q8_0.gguf"
    )

    /// 默认备用轻量模型：Whisper Tiny (44MB, 极致轻量多语言)
    public static let whisperTiny = ASRModelInfo(
        id: "whisper-tiny-q8",
        name: "Whisper Tiny (轻量备用)",
        fileName: "whisper-tiny-Q8_0.gguf",
        description: "体积仅约 44MB，覆盖近百种多国语言，支持段落级时间戳，适合微型包或外语辅助",
        approximateSizeMB: 44,
        languages: ["multilingual"]
    )

    /// 备选标准模型：Whisper Base (148MB)
    public static let whisperBase = ASRModelInfo(
        id: "whisper-base-q8",
        name: "Whisper Base",
        fileName: "whisper-base-Q8_0.gguf",
        description: "兼顾体积与识别准确率的 Whisper 标准轻量版",
        approximateSizeMB: 148,
        languages: ["multilingual"]
    )

    public static let standardModels: [ASRModelInfo] = [senseVoice, whisperTiny, whisperBase]

    /// 寻址指定模型文件所在的物理路径
    /// 优先级规则：
    /// 1. 显式环境变量覆盖 (TRANSCRIBE_MODEL_PATH, SUBTITLE_MODEL_PATH, VOICE_INPUT_MODEL)
    /// 2. App Group 共享目录 (针对 iOS 主应用与键盘扩展共享)
    /// 3. 沙盒 Application Support / Documents 目录
    /// 4. App Bundle 内置资源
    /// 5. 跨应用通用缓存 (~/.transcribe_models/ 或 ~/.1agents/models/)
    public static func resolveModelURL(for model: ASRModelInfo = senseVoice, appGroupID: String? = nil) -> URL? {
        var candidates: [URL] = []

        // 1. 环境变量覆盖
        let envKeys = ["TRANSCRIBE_MODEL_PATH", "SUBTITLE_MODEL_PATH", "VOICE_INPUT_MODEL", "TRANSCRIBE_MODELS_DIR"]
        for key in envKeys {
            if let val = ProcessInfo.processInfo.environment[key], !val.isEmpty {
                let url = URL(fileURLWithPath: val)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        candidates.append(url.appendingPathComponent(model.fileName))
                    } else {
                        // 显式指定了文件
                        candidates.append(url)
                    }
                }
            }
        }

        // 2. App Group 共享容器 (iOS/macOS Extension 协同必备)
        if let appGroupID = appGroupID,
           let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            candidates.append(groupURL.appendingPathComponent("models/\(model.fileName)"))
            candidates.append(groupURL.appendingPathComponent(model.fileName))
        }

        // 3. Application Support 目录
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("TranscribeKit/models/\(model.fileName)"))
            candidates.append(appSupport.appendingPathComponent("SmartSubtitlePlayer/models/\(model.fileName)"))
            candidates.append(appSupport.appendingPathComponent("VoiceInputMac/models/\(model.fileName)"))
        }

        // 4. 沙盒 Documents 目录
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(documents.appendingPathComponent("models/\(model.fileName)"))
            candidates.append(documents.appendingPathComponent(model.fileName))
        }

        // 5. App Bundle 内置资源
        let baseName = (model.fileName as NSString).deletingPathExtension
        let ext = (model.fileName as NSString).pathExtension
        if let bundleRes = Bundle.main.url(forResource: baseName, withExtension: ext) {
            candidates.append(bundleRes)
        }
        if let subpath = Bundle.main.url(forResource: baseName, withExtension: ext, subdirectory: "models") {
            candidates.append(subpath)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/models/\(model.fileName)"))
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("models/\(model.fileName)"))

        // 6. 开发者通用本地模型存储目录 (向后兼容)
        let homeDir = URL(fileURLWithPath: NSHomeDirectory())
        candidates.append(homeDir.appendingPathComponent(".transcribe_models/\(model.fileName)"))
        candidates.append(homeDir.appendingPathComponent(".1agents/models/\(model.fileName)"))

        // 逐一验证文件存在性与有效性
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    /// 检查指定模型是否存在且就绪
    public static func isModelAvailable(_ model: ASRModelInfo = senseVoice, appGroupID: String? = nil) -> Bool {
        resolveModelURL(for: model, appGroupID: appGroupID) != nil
    }

    /// 校验文件的 SHA256 哈希值
    public static func verifyChecksum(fileURL: URL, expectedSHA256: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB chunk
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        let computed = digest.map { String(format: "%02x", $0) }.joined()
        return computed.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }
}
