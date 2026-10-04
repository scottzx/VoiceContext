#import <Foundation/Foundation.h>
#import "ReminderOffloadContract.h"

// In-memory fixtures answer only selection properties. No EKEventStore is
// constructed, no authorization requested, and no personal data is read.
@interface ReminderListFixture : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic) BOOL allowsContentModifications;
@end
@implementation ReminderListFixture
@end

static EKCalendar *list(NSString *title, BOOL writable) {
    ReminderListFixture *fixture = [[ReminderListFixture alloc] init];
    fixture.title = title;
    fixture.allowsContentModifications = writable;
    return (EKCalendar *)fixture;
}

static void check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        EKCalendar *work = list(@"Work", YES), *homework = list(@"Homework", YES);
        EKCalendar *readOnly = list(@"Shared", NO);
        NSArray *lists = @[work, homework, readOnly];
        NSString *error = nil;
        check(reminder_resolve_list(lists, homework, @"work", YES, &error) == work, @"Exact names allow case differences");
        check(reminder_resolve_list(lists, homework, @"wor", YES, &error) == nil, @"Partial names cannot silently select a target");
        check(reminder_resolve_list(lists, homework, @"Missing", YES, &error) == nil, @"Missing explicit list cannot fall back to default");
        check(reminder_resolve_list(lists, homework, @"", YES, &error) == nil, @"Empty explicit list cannot fall back to default");
        check(reminder_resolve_list(lists, homework, @" \n", YES, &error) == nil, @"Whitespace list names are invalid");
        check(reminder_resolve_list(@[work, list(@"WORK", YES)], homework, @"Work", YES, &error) == nil, @"Same-name targets are ambiguous");
        check(reminder_resolve_list(lists, work, @"Shared", YES, &error) == nil, @"Writes must fail for read-only targets");
        check(reminder_resolve_list(lists, nil, @"Shared", NO, &error) == readOnly, @"Read-only lists remain readable");
        check(reminder_resolve_list(lists, homework, nil, YES, &error) == homework, @"Default is allowed only without an explicit name");
        check(reminder_resolve_list(lists, readOnly, nil, YES, &error) == nil, @"An unchanged read-only target is still not writable");
        check(reminder_resolve_list(lists, nil, nil, YES, &error) == nil, @"No default is a failure");

        for (NSString *invalid in @[@"", @"2026-02-30", @"2026-02-29", @"2026-13-01", @"2026-01-00",
                                   @"2026-10-03T24:00", @"2026-10-03T12:60", @"2026-10-03T12:00:60Z",
                                   @"2026-10-03T12:00:00+25:00", @"2026-10-03T12:00:00+08:60",
                                   @"2026-10-03junk", @"2026-10-03\n", @"-0d", @"-1food", @"-1.5h", @"-7d\n"]) {
            check(reminder_parse_due_components(invalid) == nil, [@"Reject invalid date: " stringByAppendingString:invalid]);
        }
        check(reminder_parse_due_components(nil) == nil, @"Missing due value is invalid");
        for (NSString *valid in @[@"2024-02-29", @"2026-10-03T00:30", @"2026-10-03T00:30:15Z",
                                 @"2026-10-03T00:30:15.125+08:00", @"-7d", @"-2h", @"-30m"]) {
            check(reminder_parse_due_components(valid) != nil, [@"Accept supported date: " stringByAppendingString:valid]);
        }
        NSDateComponents *day = reminder_parse_due_components(@"2026-10-03");
        check(day.hour == NSDateComponentUndefined && day.minute == NSDateComponentUndefined, @"Date-only due must have no time");
        check([day.calendar.calendarIdentifier isEqualToString:NSCalendarIdentifierGregorian], @"ISO dates use Gregorian components");
        check(![reminder_due_dict(day)[@"due_has_time"] boolValue], @"Date-only receipt must not claim a time");
        check(reminder_due_dict(day)[@"due_components"][@"hour"] == NSNull.null &&
              reminder_due_dict(day)[@"due_components"][@"minute"] == NSNull.null &&
              reminder_due_dict(day)[@"due_components"][@"second"] == NSNull.null, @"All-day readback must preserve absent fields");

        NSDateComponents *offset = reminder_parse_due_components(@"2026-10-03T00:30:15.125+08:00");
        NSDate *instant = [offset.calendar dateFromComponents:offset];
        check(offset.day == 3 && offset.hour == 0 && offset.minute == 30 && offset.nanosecond == 125000000, @"Input components survive a UTC cross-day conversion");
        check([offset.timeZone secondsFromGMTForDate:instant] == 8 * 3600, @"Explicit timezone is preserved");
        NSDictionary *receipt = reminder_due_dict(offset);
        check([receipt[@"due"] isEqualToString:@"2026-10-03T00:30:15+08:00"], @"Receipt uses the saved offset and date, not the device timezone");
        check([receipt[@"timezone"] isEqualToString:offset.timeZone.name] && [receipt[@"due_has_time"] boolValue], @"Receipt reports stored timezone and time presence");
        check([receipt[@"due_components"][@"nanosecond"] integerValue] == 125000000 &&
              [receipt[@"due_components"][@"calendar"] isEqualToString:NSCalendarIdentifierGregorian], @"Raw readback preserves subseconds and calendar");
        NSDictionary *noDue = reminder_due_dict(nil);
        check(noDue[@"due"] == NSNull.null && noDue[@"timezone"] == NSNull.null && noDue[@"due_components"] == NSNull.null &&
              ![noDue[@"due_has_time"] boolValue], @"No due means no invented date or timezone");
        puts("Reminder contract regressions passed: exact/ambiguous/missing/read-only/default lists, strict dates, all-day, explicit timezone and readback");
    }
    return 0;
}
