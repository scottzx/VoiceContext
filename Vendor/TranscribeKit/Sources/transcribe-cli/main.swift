import Foundation
import TranscribeKit

// MARK: - Model Downloader (ModelScope Integration)

final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var expectedBytes: Int64 = 0
    private var lastPrintTime: Date = Date()

    func download(from url: URL, to destinationURL: URL, expectedSHA256: String?) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let tempURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            task.resume()
        }

        // 校验 SHA256 (若有)
        if let expected = expectedSHA256 {
            fflush(stdout)
            print("\n🔍 正在校验模型 SHA256 完整性...")
            if !ModelRegistry.verifyChecksum(fileURL: tempURL, expectedSHA256: expected) {
                try? FileManager.default.removeItem(at: tempURL)
                throw NSError(domain: "ModelDownloader", code: -2, userInfo: [NSLocalizedDescriptionKey: "模型 SHA256 校验失败，文件可能已损坏"])
            }
            print("✅ SHA256 校验通过！")
        }

        // 移动到目标路径
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        return destinationURL
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if expectedBytes <= 0 && totalBytesExpectedToWrite > 0 {
            expectedBytes = totalBytesExpectedToWrite
        }
        let now = Date()
        guard now.timeIntervalSince(lastPrintTime) > 0.15 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastPrintTime = now

        let percent: Double
        let totalStr: String
        if expectedBytes > 0 {
            percent = min(1.0, Double(totalBytesWritten) / Double(expectedBytes))
            totalStr = String(format: "%.1fMB", Double(expectedBytes) / 1024.0 / 1024.0)
        } else {
            percent = 0
            totalStr = "未知大小"
        }

        let downloadedStr = String(format: "%.1fMB", Double(totalBytesWritten) / 1024.0 / 1024.0)
        let barLength = 28
        let filled = Int(Double(barLength) * percent)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: max(0, barLength - filled))

        let line = String(format: "\r📥 正在从 ModelScope 下载 [%@] %3.0f%% (%@ / %@)", bar, percent * 100.0, downloadedStr, totalStr)
        fputs(line, stderr)
        fflush(stderr)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempDestination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            try FileManager.default.moveItem(at: location, to: tempDestination)
            fputs("\n", stderr)
            continuation?.resume(returning: tempDestination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            fputs("\n", stderr)
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - CLI Logic

@main
struct TranscribeCLI {
    static func printUsage() {
        let usage = """
        TranscribeKit CLI (Metal 硬件加速端侧离线语音转写)

        用法:
          transcribe-cli <音频文件路径> [选项]

        选项:
          -o, --output <路径>       指定输出目录或文件（默认保存在音频同级目录）
          -f, --format <格式>       输出格式：srt, vtt, txt, all（默认：all）
          -l, --lang <语种>         语言提示：zh (默认), en, yue, ja, ko
          --no-itn                  关闭逆文本规整 (ITN)
          -m, --model <模型路径>     显式指定本地 GGUF 模型文件
          -h, --help                显示帮助信息

        示例:
          transcribe-cli input.mp3
          transcribe-cli podcast.m4a -o ~/Desktop/transcripts/ -f srt
        """
        print(usage)
    }

    static func ensureModelAvailable(specifiedPath: String?) async throws -> URL {
        if let path = specifiedPath {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(domain: "TranscribeCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: "指定的模型文件不存在: \(path)"])
            }
            return url
        }

        let modelInfo = ModelRegistry.senseVoice
        if let localURL = ModelRegistry.resolveModelURL(for: modelInfo) {
            return localURL
        }

        // 本地未找到，从 ModelScope 自动下载
        print("📦 本地未检测到 ASR 模型 [\(modelInfo.fileName)]")
        guard let downloadURLString = modelInfo.downloadURL, let downloadURL = URL(string: downloadURLString) else {
            throw NSError(domain: "TranscribeCLI", code: -2, userInfo: [NSLocalizedDescriptionKey: "模型元数据缺少下载地址"])
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let targetDir = home.appendingPathComponent(".transcribe_models")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetFile = targetDir.appendingPathComponent(modelInfo.fileName)

        print("🌐 准备从 ModelScope 镜像源极速下载至: \(targetFile.path)")
        let downloader = ModelDownloader()
        return try await downloader.download(from: downloadURL, to: targetFile, expectedSHA256: modelInfo.expectedSHA256)
    }

    static func main() async {
        let args = CommandLine.arguments
        if args.count <= 1 || args.contains("-h") || args.contains("--help") {
            printUsage()
            exit(0)
        }

        var inputPath: String?
        var outputPath: String?
        var format: String = "all"
        var language: String? = "zh"
        var itn: Bool = true
        var modelPath: String?

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-o", "--output":
                if i + 1 < args.count { outputPath = args[i + 1]; i += 1 }
            case "-f", "--format":
                if i + 1 < args.count { format = args[i + 1].lowercased(); i += 1 }
            case "-l", "--lang":
                if i + 1 < args.count { language = args[i + 1]; i += 1 }
            case "-m", "--model":
                if i + 1 < args.count { modelPath = args[i + 1]; i += 1 }
            case "--no-itn":
                itn = false
            default:
                if !arg.hasPrefix("-") && inputPath == nil {
                    inputPath = arg
                }
            }
            i += 1
        }

        guard let input = inputPath else {
            print("❌ 错误：必须提供输入音频路径。")
            printUsage()
            exit(1)
        }

        let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            print("❌ 错误：输入文件不存在: \(inputURL.path)")
            exit(1)
        }

        print("\n🚀 [TranscribeKit] 启动音频转写管线...")
        print("📁 输入文件: \(inputURL.lastPathComponent)")

        do {
            let startTime = Date()

            // 1. 确保模型就绪
            let modelURL = try await ensureModelAvailable(specifiedPath: modelPath)
            print("🎯 ASR 模型: \(modelURL.lastPathComponent)")

            // 2. 加载引擎
            let engine = StandardTranscriber()
            try engine.load(modelURL: modelURL)
            print("⚡ 推理后端: \(engine.backendName)")

            // 3. 执行管线
            let pipeline = MediaSubtitlePipeline()
            let options = TranscribeOptions(language: language, itn: itn)

            let items = try await pipeline.process(mediaURL: inputURL, engine: engine, options: options) { progress in
                let pct = Int(progress.fractionCompleted * 100)
                let line = "\r🔄 进度 [\(pct)%]: \(progress.message)"
                fputs(line.padding(toLength: 60, withPad: " ", startingAt: 0), stderr)
                fflush(stderr)
            }
            fputs("\n", stderr)

            let elapsed = Date().timeIntervalSince(startTime)
            let audioDurationSec = Double(items.last?.endTimeMs ?? 0) / 1000.0
            let rtf = audioDurationSec > 0 ? audioDurationSec / elapsed : 0

            print("\n✨ 转写完成！")
            print(String(format: "⏱️  音频时长: %.1f 秒 | 转写耗时: %.1f 秒 | 加速比: %.1fx 实时", audioDurationSec, elapsed, rtf))
            print("📝 总字幕条目: \(items.count) 句\n")

            // 4. 确定输出路径与格式导出
            let baseName = inputURL.deletingPathExtension().lastPathComponent
            let outputDir: URL
            if let out = outputPath {
                let expanded = (out as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue {
                    outputDir = URL(fileURLWithPath: expanded)
                } else if !out.contains(".") {
                    // 没有后缀视为目录
                    try FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
                    outputDir = URL(fileURLWithPath: expanded)
                } else {
                    outputDir = URL(fileURLWithPath: expanded).deletingLastPathComponent()
                }
            } else {
                outputDir = inputURL.deletingLastPathComponent()
            }

            let srtContent = SubtitleExporter.toSRT(items)
            let vttContent = SubtitleExporter.toVTT(items)
            let txtContent = items.map { $0.originalText }.joined(separator: "\n")

            if format == "srt" || format == "all" {
                let srtURL = outputDir.appendingPathComponent("\(baseName).srt")
                try srtContent.write(to: srtURL, atomically: true, encoding: .utf8)
                print("📄 SRT 字幕: \(srtURL.path)")
            }

            if format == "vtt" || format == "all" {
                let vttURL = outputDir.appendingPathComponent("\(baseName).vtt")
                try vttContent.write(to: vttURL, atomically: true, encoding: .utf8)
                print("📄 VTT 字幕: \(vttURL.path)")
            }

            if format == "txt" || format == "all" {
                let txtURL = outputDir.appendingPathComponent("\(baseName).txt")
                try txtContent.write(to: txtURL, atomically: true, encoding: .utf8)
                print("📝 纯文本稿: \(txtURL.path)")
            }

            print("\n🎉 全部处理完成！")
        } catch {
            print("\n❌ 转写失败: \(error.localizedDescription)")
            exit(1)
        }
    }
}
