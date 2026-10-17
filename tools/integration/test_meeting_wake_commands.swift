import Foundation

@main struct MeetingWakeCommandTextChecks {
    static func main() {
        let cases = [
            ("小蓝同学，查今天的待办。", "查今天的待办。"),
            ("小兰同学，查日程。", "查日程。"),
            (" 小，兰 同学：帮我记下来 ", "帮我记下来"),
            ("小蓝同学", ""), ("小兰同学。", ""),
            ("，查一下日程", "查一下日程"),
            ("给小蓝同学创建待办", "给小蓝同学创建待办"),
            ("小林同学查待办", "小林同学查待办"),
            ("，。 ", "")
        ]
        for (text, expected) in cases {
            precondition(MeetingWakeCommandText.command(from: text) == expected, text)
        }
        let independent: [(String, MeetingWakeCommandText.IndependentCommand)] = [
            ("小蓝同学", .wakeOnly), ("小蓝同学！", .wakeOnly),
            (" 小，兰 同学： ", .wakeOnly), ("小蓝同学……", .wakeOnly),
            ("小蓝同学，回", .command("回")), ("小蓝同学停", .command("停")),
            ("小蓝同学，打开日程。", .command("打开日程。")),
            ("返回", .command("返回")), ("回", .command("回")),
            ("小蓝同学，打开今天的日程", .command("打开今天的日程")),
            ("给小蓝同学创建待办", .command("给小蓝同学创建待办")),
            ("小林同学", .command("小林同学")),
            ("，。 ", .empty), ("", .empty)
        ]
        for (text, expected) in independent {
            precondition(MeetingWakeCommandText.classifyIndependent(text) == expected, text)
        }
        print("Acoustically authorized command text and exact homophone cleanup passed")
    }
}
