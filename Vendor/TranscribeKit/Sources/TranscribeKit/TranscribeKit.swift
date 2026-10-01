// 顶层伞模块：一键导出 TranscribeKit 所有核心能力
@_exported import TranscribeNative
@_exported import TranscribeCore
@_exported import TranscribePipeline
@_exported import TranscribeStreaming

public enum TranscribeInfo {
    /// 框架版本
    public static let version = "1.0.0"

    /// 便捷实例化默认离线 ASR 引擎（SenseVoice）
    public static func makeDefaultTranscriber() throws -> StandardTranscriber {
        let transcriber = StandardTranscriber()
        try transcriber.loadModel(ModelRegistry.senseVoice)
        return transcriber
    }
}
