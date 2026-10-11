import Foundation

@main
struct MeetingWakeCommandChecks {
    static func main() {
        var detector = MeetingWakeCommandDetector()
        func segment(_ text: String, _ start: Int64, _ end: Int64) -> MeetingWakeCommandDetector.Segment {
            .init(text: text, startSample: start * 16_000, endSample: end * 16_000)
        }
        func consume(_ segments: [MeetingWakeCommandDetector.Segment], id: UUID = UUID()) -> String? {
            detector.consume(chunkID: id, segments: segments)
        }

        precondition(consume([segment("今天我们先讨论下周的计划。", 0, 2)]) == nil)
        precondition(consume([segment("小林同学，查询待办。", 2, 4)]) == nil, "Do not accept homophone aliases")
        precondition(consume([segment("小蓝同学，查一下今天的待办。", 4, 6)]) == "查一下今天的待办。")
        precondition(consume([segment("小、蓝 同\n学： 查询明天的日程。", 6, 8)]) == "查询明天的日程。")
        precondition(consume([
            segment("先说一下进度。小蓝同学，帮我建个待办。", 8, 10),
            segment("明天下午联系王总，问合同进度。", 10, 12)
        ]) == "帮我建个待办。 明天下午联系王总，问合同进度。", "Keep the completed chunk's remaining sentences readable")

        precondition(consume([segment("小蓝同学。", 12, 13)]) == nil)
        precondition(consume([segment("……帮我查询接下来的安排。", 14, 15)]) == "帮我查询接下来的安排。")
        precondition(consume([
            segment("小蓝同学。", 15, 16),
            segment("查待办。", 16, 17)
        ]) == "查待办。")
        precondition(consume([segment("大家先等一下，小蓝", 17, 18)]) == nil)
        precondition(consume([segment("同学，查明天的日程。", 18, 19)]) == "查明天的日程。")
        precondition(consume([segment("小", 19, 20)]) == nil)
        precondition(consume([segment("蓝同", 20, 21)]) == nil)
        precondition(consume([segment("学：记下这件事。", 21, 22)]) == "记下这件事。")
        precondition(consume([segment("小蓝同学", 22, 23)]) == nil)
        precondition(consume([segment("查今天的待办。", 31, 32)]) == "查今天的待办。", "The eight-second boundary is inclusive")
        precondition(consume([segment("小蓝同学", 32, 33)]) == nil)
        precondition(consume([segment("这是普通会议发言。", 42, 43)]) == nil, "Expire a standalone wake word")
        precondition(consume([segment("小蓝", 43, 44)]) == nil)
        precondition(consume([segment("同学，查待办。", 53, 54)]) == nil, "Expire an incomplete wake word")
        precondition(consume([segment("小蓝", 54, 55)]) == nil)
        precondition(consume([segment("大家继续讨论。", 55, 56)]) == nil)
        precondition(consume([segment("同学，查待办。", 56, 57)]) == nil, "Do not join a keyword across other speech")

        let chunkID = UUID()
        precondition(consume([segment("小蓝同学，查待办。", 57, 58)], id: chunkID) == "查待办。")
        precondition(consume([segment("小蓝同学，创建待办。", 58, 59)], id: chunkID) == nil, "Do not reprocess a chunk ID")
        precondition(consume([segment("小蓝同学，创建待办。", 50, 51)]) == nil, "Reject out-of-order results")
        precondition(consume([segment("小蓝同学，创建待办。", 57, 59)]) == nil, "Reject overlapping results")
        precondition(consume([segment("小蓝同学", 59, 60)]) == nil)
        precondition(consume([segment("小蓝同学，旧指令。", 40, 41)]) == nil)
        precondition(consume([segment("查下周日程。", 60, 61)]) == "查下周日程。", "An old result must not disturb a live wake")

        detector.reset(afterSample: 70 * 16_000)
        precondition(consume([segment("小蓝同学，历史指令。", 65, 69)]) == nil)
        precondition(consume([segment("小蓝同学，跨越启用边界。", 69, 71)]) == nil)
        precondition(consume([segment("小蓝同学，新的指令。", 70, 71)]) == "新的指令。")
        precondition(consume([segment("小蓝同学", 71, 72)]) == nil)
        detector.reset(afterSample: 73 * 16_000)
        precondition(consume([segment("这是恢复后的普通发言。", 73, 74)]) == nil, "Reset clears a waiting wake word")

        precondition(consume([segment("小蓝同学", 74, 75)]) == nil)
        detector.suppress(from: 75 * 16_000, to: 77 * 16_000)
        precondition(consume([segment("小蓝同学，外放的指令。", 75, 76)]) == nil)
        precondition(consume([segment("播报跨越抑制边界。小蓝同学，查待办。", 76, 78)]) == nil)
        precondition(consume([segment("会议继续。", 78, 79)]) == nil, "TTS clears an earlier waiting wake word")
        precondition(consume([segment("小蓝同学，正常请求。", 79, 80)]) == "正常请求。")
        precondition(consume([segment("小蓝", 80, 81)]) == nil)
        detector.suppress(from: 81 * 16_000, to: 82 * 16_000)
        precondition(consume([segment("同学，查待办。", 82, 83)]) == nil, "TTS clears an incomplete wake word")
        precondition(consume([segment("小蓝同学，抑制结束后的请求。", 83, 84)]) == "抑制结束后的请求。")

        detector.suppress(from: 86 * 16_000, to: 87 * 16_000)
        precondition(consume([segment("小蓝同学", 84, 85)]) == nil)
        precondition(consume([segment("播报声音。", 86, 87)]) == nil)
        precondition(consume([segment("普通会议发言。", 87, 88)]) == nil, "A suppressed sentence clears a later waiting wake")
        precondition(consume([segment("小", 88, 89)]) == nil)
        precondition(consume([segment("蓝同", 96, 97)]) == nil)
        precondition(consume([segment("学，查待办。", 98, 99)]) == nil, "An incomplete keyword cannot keep extending its deadline")

        detector.reset(afterSample: 0)
        precondition(consume([]) == nil)
        precondition(consume([segment("小蓝同学，时间范围无效。", 0, 0)]) == nil)
        precondition(consume([
            segment("第二句话。", 2, 3),
            segment("小蓝同学，第一句话。", 0, 2)
        ]) == "第一句话。 第二句话。", "Process sentences in audio order")
        print("Meeting wake command, timeline, deduplication, timeout and TTS suppression checks passed")
    }
}
