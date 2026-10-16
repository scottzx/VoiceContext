import Foundation

// Only non-voice dependencies are stubbed; the request and adapter are real.
struct LLMModel { let id: String; let displayName: String }
struct AppLogger {
    init(category: String) {}
    func info(_ message: String) {}
    func error(_ message: String) {}
}
func AppLocalized(_ value: String, comment: String = "") -> String { value }

@main
struct MiniMaxTTSChecks {
    static func main() throws {
        let bases = [
            "https://api.minimax.cn/anthropic",
            "https://api.minimax.io/anthropic/v1/",
            "https://api.minimaxi.com/v1",
            "https://api.minimax.io"
        ]
        for base in bases {
            let provider = MiniMaxVoiceProvider(providerId: "test", baseURL: base, apiKey: "test-key")
            let request = try provider.buildVoiceOutputRequest(.init(input: "收到，正在执行。", model: "speech-2.8-hd"))
            precondition(request.url?.path == "/v1/t2a_v2", "Chat endpoint must not leak into TTS")
            precondition(request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let voice = body["voice_setting"] as! [String: Any]
            precondition((voice["speed"] as! NSNumber).doubleValue == 1, "MiniMax speed is a multiplier")
            precondition((voice["vol"] as! NSNumber).doubleValue == 1, "MiniMax normal volume is 1")
            precondition(voice["voice_id"] as? String == "female-shaonv")
            precondition(body["model"] as? String == "speech-2.8-hd")
            precondition(body["stream"] as? Bool == false)
        }
        let provider = MiniMaxVoiceProvider(providerId: "test", baseURL: bases[0])
        for (speed, expected) in [(Float(0.25), 0.5), (1.25, 1.25), (4, 2)] {
            let request = try provider.buildVoiceOutputRequest(.init(
                input: "测试", model: "speech-2.8-turbo", voice: "speech-2.8-turbo", speed: speed
            ))
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let voice = body["voice_setting"] as! [String: Any]
            precondition((voice["speed"] as! NSNumber).doubleValue == expected)
            precondition(voice["voice_id"] as? String == "female-shaonv", "Model ID is not a voice ID")
            precondition(body["model"] as? String == "speech-2.8-turbo")
        }
        print("PASS: MiniMax TTS endpoint, auth, model/voice and numeric parameters")
    }
}
