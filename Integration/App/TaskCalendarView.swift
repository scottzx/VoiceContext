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
    @State private var showLegend = false
    private var calendar: Calendar { .current }
    private var days: [Date] { TaskCalendarRules.days(month: month, selected: selected, expanded: expanded) }

    var body: some View {
        VStack(spacing: YimaDesign.Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack { monthControl; Spacer(minLength: YimaDesign.Space.xs); todayControls }
                VStack(alignment: .leading, spacing: YimaDesign.Space.xs) {
                    monthControl
                    HStack { Spacer(minLength: 0); todayControls }
                }
            }.padding(.horizontal, YimaDesign.Space.sm)
            if typeSize.isAccessibilitySize {
                Button("选择日期") { datePicker = true }
                    .frame(maxWidth: .infinity, minHeight: YimaDesign.Layout.hitTarget)
            }
            HStack(spacing: 0) {
                // Always Monday first, regardless of the system's firstWeekday preference.
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { index in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[index])
                        .font(YimaDesign.Typography.compactMetadata).foregroundStyle(YimaDesign.Color.muted).frame(maxWidth: .infinity, minHeight: 32)
                }
            }.accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in dateCell(day) }
            }
            .contentShape(Rectangle())
            .background(TaskCalendarSwipeRegion(page: page))
        }
        .buttonStyle(.plain)
        .padding(YimaDesign.Space.sm)
        .background(YimaDesign.Color.grouped, in: RoundedRectangle(cornerRadius: YimaDesign.Radius.panel))
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

    private var monthControl: some View {
        Button {
            month = selected
            expanded.toggle()
        } label: {
            HStack(spacing: YimaDesign.Space.sm) {
                Text(month, format: .dateTime.year().month(.twoDigits))
                    .font(YimaDesign.Typography.section).monospacedDigit()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(YimaDesign.Typography.compactMetadata).foregroundStyle(YimaDesign.Color.muted)
            }.frame(minHeight: YimaDesign.Layout.hitTarget)
        }
        .accessibilityLabel(expanded ? "收起为周历" : "展开月历")
    }

    private var todayControls: some View {
        HStack(spacing: 0) {
            Button("今天") { selected = Date(); month = selected }
                .font(YimaDesign.Typography.metadata.weight(.medium)).frame(minWidth: YimaDesign.Layout.hitTarget, minHeight: YimaDesign.Layout.hitTarget)
            Button { showLegend = true } label: {
                Image(systemName: "info.circle").font(YimaDesign.Typography.body).frame(width: YimaDesign.Layout.hitTarget, height: YimaDesign.Layout.hitTarget)
            }
            .accessibilityLabel("日历标记说明")
            .popover(isPresented: $showLegend, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: YimaDesign.Space.md) {
                    legend("红色：待办", color: YimaDesign.Color.reminderDot)
                    legend("绿色：日程", color: YimaDesign.Color.eventDot)
                }.padding(YimaDesign.Layout.pageInset).presentationCompactAdaptation(.popover)
            }
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
            VStack(spacing: YimaDesign.Space.xs) {
                Text("\(calendar.component(.day, from: day))")
                    .font(YimaDesign.Typography.body.weight(chosen ? .semibold : .regular)).monospacedDigit()
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(width: 34, height: 32)
                    .foregroundStyle(chosen ? YimaDesign.Color.canvas : YimaDesign.Color.ink)
                    .background(chosen ? YimaDesign.Color.ink : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(today ? YimaDesign.Color.ink : .clear, lineWidth: 1) }
                    .opacity(chosen || calendar.isDate(day, equalTo: month, toGranularity: .month) ? 1 : 0.55)
                HStack(spacing: YimaDesign.Space.xs) {
                    Circle().fill(YimaDesign.Color.reminderDot).frame(width: 4, height: 4).opacity((data.reminders ?? 0) > 0 ? 1 : 0)
                    Circle().fill(YimaDesign.Color.eventDot).frame(width: 4, height: 4).opacity((data.events ?? 0) > 0 ? 1 : 0)
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
            Text(title).font(YimaDesign.Typography.metadata).foregroundStyle(YimaDesign.Color.ink)
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
