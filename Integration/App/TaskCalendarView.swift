import SwiftUI

struct TaskDayCounts {
    var reminders: Int?
    var events: Int?
}

struct TaskCalendarView: View {
    @Binding var selected: Date
    @Binding var month: Date
    @Binding var expanded: Bool
    let counts: (Date) -> TaskDayCounts
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var datePicker = false
    private var calendar: Calendar { .current }
    private var days: [Date] { TaskCalendarRules.days(month: month, selected: selected, expanded: expanded) }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Button {
                    month = selected
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(month, format: .dateTime.year().month(.twoDigits))
                            .font(.title2.weight(.bold)).monospacedDigit()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
                .accessibilityLabel(expanded ? "收起为周历" : "展开月历")
                Spacer(minLength: 4)
                Button("今天") { selected = Date(); month = selected }
                    .font(.subheadline.weight(.medium)).frame(minWidth: 44, minHeight: 44)
            }.padding(.horizontal, 8)
            if typeSize.isAccessibilitySize {
                Button("选择日期") { datePicker = true }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            HStack(spacing: 0) {
                // Always Monday first, regardless of the system's firstWeekday preference.
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { index in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[index])
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 32)
                }
            }.accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in dateCell(day) }
            }
            .contentShape(Rectangle())
            .background(TaskCalendarSwipeRegion(page: page))
            HStack(spacing: 16) {
                legend("待办", color: .red)
                legend("日程", color: .green)
            }.padding(.top, 8)
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityActions {
            Button(expanded ? "上一月" : "上一周") { page(-1) }
            Button(expanded ? "下一月" : "下一周") { page(1) }
            Button("选择日期") { datePicker = true }
        }
        .onAppear { if typeSize.isAccessibilitySize { expanded = false } }
        .onChange(of: typeSize) { _, value in if value.isAccessibilitySize { expanded = false; month = selected } }
        .sheet(isPresented: $datePicker) {
            NavigationStack {
                DatePicker("选择日期", selection: $selected, displayedComponents: .date)
                    .datePickerStyle(.graphical).padding()
                    .navigationTitle("选择日期").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { month = selected; datePicker = false } } }
            }.presentationDetents([.medium, .large])
        }
    }

    private func page(_ step: Int) {
        let next = TaskCalendarRules.page(month: month, selected: selected, expanded: expanded, step: step)
        month = next.month; selected = next.selected
    }

    private func dateCell(_ day: Date) -> some View {
        let chosen = calendar.isDate(day, inSameDayAs: selected)
        let today = calendar.isDateInToday(day)
        let data = counts(day)
        return Button { selected = day; month = day } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.body.weight(chosen ? .semibold : .regular)).monospacedDigit()
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(width: 34, height: 32)
                    .foregroundStyle(chosen ? Color(uiColor: .systemBackground) : Color.primary)
                    .background(chosen ? Color.primary : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(today ? Color.primary : .clear, lineWidth: 1) }
                    .opacity(chosen || calendar.isDate(day, equalTo: month, toGranularity: .month) ? 1 : 0.55)
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 4, height: 4).opacity((data.reminders ?? 0) > 0 ? 1 : 0)
                    Circle().fill(.green).frame(width: 4, height: 4).opacity((data.events ?? 0) > 0 ? 1 : 0)
                }.accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
        }
        .accessibilityLabel(Text(day, format: .dateTime.year().month().day().weekday(.wide)))
        .accessibilityValue(Text(verbatim: (today ? AppLocalized("今天") + "，" : "") + countDescription(data)))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func countDescription(_ counts: TaskDayCounts) -> String {
        let reminders = counts.reminders.map { AppLocalized("\($0) 项待办") } ?? AppLocalized("待办未读取")
        let events = counts.events.map { AppLocalized("\($0) 项日程") } ?? AppLocalized("日程未读取")
        return reminders + "，" + events
    }

    private func legend(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 4, height: 4).accessibilityHidden(true)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Fail vertical gestures before recognition so the native List can scroll.
/// A recognized horizontal drag cancels the date button's touch.
private struct TaskCalendarSwipeRegion: UIViewRepresentable {
    let page: (Int) -> Void
    func makeUIView(context: Context) -> SwipeView { SwipeView() }
    func updateUIView(_ view: SwipeView, context: Context) { view.page = page }
    static func dismantleUIView(_ view: SwipeView, coordinator: ()) { view.detach() }

    final class SwipeView: UIView, UIGestureRecognizerDelegate {
        var page: ((Int) -> Void)?
        private weak var scroll: UIScrollView?
        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard window != nil else { return }
            isUserInteractionEnabled = false
            var ancestor = superview
            while let view = ancestor {
                if let list = view as? UIScrollView {
                    scroll = list
                    pan.delegate = self
                    list.addGestureRecognizer(pan)
                    list.panGestureRecognizer.require(toFail: pan)
                    break
                }
                ancestor = view.superview
            }
        }

        func detach() { scroll?.removeGestureRecognizer(pan); scroll = nil }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            bounds.contains(touch.location(in: self))
        }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = pan.velocity(in: self)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
        @objc private func dragged() {
            guard pan.state == .ended else { return }
            let distance = pan.translation(in: self)
            guard abs(distance.x) >= 48, abs(distance.x) > abs(distance.y) * 1.5 else { return }
            page?(distance.x < 0 ? 1 : -1)
        }
    }
}
