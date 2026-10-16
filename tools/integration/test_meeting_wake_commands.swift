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
        print("Acoustically authorized command text and exact homophone cleanup passed")
    }
}
