import UIKit
import SwiftUI

@MainActor
enum ScreenshotAutomation {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiAutoExportScreenshots")
    }

    static func captureKeyWindow() -> UIImage? {
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = windowScene.screen.scale
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    static func saveScreenshot(_ image: UIImage, name: String) {
        guard let data = image.pngData() else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(name).png")
        try? data.write(to: fileURL)
        print("[SCREENSHOT_EXPORTED] Saved \(name) (\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))) to \(fileURL.path)")
    }

    static func seedSampleData(model: RecordingCoreModel) async {
        let now = Date()
        let startedAt = now.addingTimeInterval(-3600)
        let meetingID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!

        let meeting = Recording(
            id: meetingID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(420),
            title: "产品架构与本地离线转写讨论",
            isMeeting: true,
            speakerProcessingEnabled: true,
            state: .complete,
            updatedAt: startedAt.addingTimeInterval(420),
            origin: .microphone,
            languageMode: .chinese,
            locationName: "上海市 · 创意园区会议室"
        )

        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let note = Recording(
            id: noteID,
            startedAt: now.addingTimeInterval(-7200),
            endedAt: now.addingTimeInterval(-7140),
            title: "关于隐私优先与端侧 AI 的思考笔记",
            isMeeting: false,
            speakerProcessingEnabled: false,
            state: .complete,
            updatedAt: now.addingTimeInterval(-7140),
            origin: .microphone,
            languageMode: .chinese,
            locationName: "上海市 · 办公室"
        )

        let chunk = AudioChunk(
            recordingID: meeting.id,
            relativePath: "Recordings/meeting_chunk.m4a",
            startSample: 0,
            endSample: 6_720_000,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(420)
        )

        let segmentTexts: [(chunkID: UUID, text: String)] = [
            (chunkID: chunk.id, text: "我们今天主要对齐一下听记 1.0 的本地端侧架构，所有语音数据默认在设备本地完成转写与处理。"),
            (chunkID: chunk.id, text: "SenseVoice 本地模型和 Pyannote 声纹分离全部在 NPU 上加速运行，无需网络也能秒级输出逐字稿。"),
            (chunkID: chunk.id, text: "是的，同时支持导出 Markdown、TXT、SRT 以及 JSON 格式，方便无缝归档与后续整理。")
        ]

        let doc = TranscriptDocumentV1(
            recording: meeting,
            chunks: [chunk],
            segmentTexts: segmentTexts,
            language: "zh",
            state: .complete,
            speakers: ["张经理", "李工"]
        )

        do {
            try? await model.repository.createRecording(meeting, at: meeting.startedAt)
            try? await model.repository.createRecording(note, at: note.startedAt)
            try? await model.repository.addChunk(chunk, at: chunk.endedAt)

            let store = try TranscriptDocumentStore(rootURL: model.repository.rootURL)
            try await store.write(doc)
        } catch {
            print("[SCREENSHOT_SEED_ERROR] \(error)")
        }
    }
}
