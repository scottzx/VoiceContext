#pragma once
#import <Foundation/Foundation.h>
#import <EventKit/EventKit.h>
#include <math.h>

// Keep selection independent of EventKit reads so UI/tool contract cases can
// be checked without querying a user's reminder store.
static EKCalendar *reminder_resolve_list(NSArray<EKCalendar *> *calendars,
                                        EKCalendar *defaultCalendar,
                                        NSString *name, BOOL writable,
                                        NSString **error) {
    EKCalendar *selected = defaultCalendar;
    if (name != nil) {
        if ([name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) {
            *error = @"--list requires a non-empty exact reminder list name.";
            return nil;
        }
        NSMutableArray<EKCalendar *> *matches = [NSMutableArray array];
        for (EKCalendar *calendar in calendars) {
            if ([calendar.title caseInsensitiveCompare:name] == NSOrderedSame) [matches addObject:calendar];
        }
        if (matches.count != 1) {
            *error = matches.count == 0
                ? [NSString stringWithFormat:@"No reminder list has the exact name '%@'.", name]
                : [NSString stringWithFormat:@"Reminder list name '%@' is ambiguous (%lu matches). Rename the target list before retrying.", name, (unsigned long)matches.count];
            return nil;
        }
        selected = matches.firstObject;
    }
    if (!selected) { *error = @"No default reminder list is available."; return nil; }
    if (writable && !selected.allowsContentModifications) {
        *error = @"The selected reminder list is read-only.";
        return nil;
    }
    return selected;
}

// NSDateFormatter may normalize invalid days. Construct and round-trip the
// explicit components instead, including the requested time zone.
static NSDateComponents *reminder_parse_due_components(NSString *value) {
    if (!value.length) return nil;
    if ([value hasPrefix:@"-"]) {
        NSRegularExpression *relative = [NSRegularExpression regularExpressionWithPattern:@"^-([1-9][0-9]*)([dhm])$" options:0 error:nil];
        NSTextCheckingResult *match = [relative firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
        if (!match || match.range.length != value.length) return nil;
        double amount = [[value substringWithRange:[match rangeAtIndex:1]] doubleValue];
        NSString *unit = [value substringWithRange:[match rangeAtIndex:2]];
        double seconds = amount * ([unit isEqualToString:@"d"] ? 86400 : [unit isEqualToString:@"h"] ? 3600 : 60);
        if (!isfinite(seconds)) return nil;
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.timeZone = NSTimeZone.localTimeZone;
        NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
            NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:[NSDate dateWithTimeIntervalSinceNow:-seconds]];
        components.calendar = calendar;
        components.timeZone = calendar.timeZone;
        return components;
    }
    NSRegularExpression *iso = [NSRegularExpression regularExpressionWithPattern:
        @"^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\\.([0-9]{1,9}))?)?(Z|[+-][0-9]{2}:?[0-9]{2})?)?$" options:0 error:nil];
    NSTextCheckingResult *match = [iso firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
    if (!match || match.range.length != value.length) return nil;
    NSInteger (^part)(NSUInteger) = ^NSInteger(NSUInteger index) {
        NSRange range = [match rangeAtIndex:index];
        return range.location == NSNotFound ? 0 : [[value substringWithRange:range] integerValue];
    };
    NSTimeZone *zone = NSTimeZone.localTimeZone;
    NSRange zoneRange = [match rangeAtIndex:8];
    if (zoneRange.location != NSNotFound) {
        NSString *offset = [[value substringWithRange:zoneRange] stringByReplacingOccurrencesOfString:@":" withString:@""];
        NSInteger seconds = 0;
        if (![offset isEqualToString:@"Z"]) {
            NSInteger hours = [[offset substringWithRange:NSMakeRange(1, 2)] integerValue];
            NSInteger minutes = [[offset substringWithRange:NSMakeRange(3, 2)] integerValue];
            if (hours > 23 || minutes > 59) return nil;
            seconds = (hours * 3600 + minutes * 60) * ([offset hasPrefix:@"-"] ? -1 : 1);
        }
        zone = [NSTimeZone timeZoneForSecondsFromGMT:seconds];
        if (!zone) return nil;
    }
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = zone;
    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.year = part(1); components.month = part(2); components.day = part(3);
    components.hour = part(4); components.minute = part(5); components.second = part(6);
    if (components.year < 1 || components.hour > 23 || components.minute > 59 || components.second > 59) return nil;
    NSDate *date = [calendar dateFromComponents:components];
    if (!date) return nil;
    NSDateComponents *actual = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
        NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:date];
    if (actual.year != components.year || actual.month != components.month || actual.day != components.day ||
        actual.hour != components.hour || actual.minute != components.minute || actual.second != components.second) return nil;
    NSRange fractionRange = [match rangeAtIndex:7];
    if (fractionRange.location != NSNotFound) {
        double fraction = [[@"0." stringByAppendingString:[value substringWithRange:fractionRange]] doubleValue];
        components.nanosecond = (NSInteger)llround(fraction * 1000000000);
    }
    if ([match rangeAtIndex:4].location == NSNotFound) {
        components.hour = NSDateComponentUndefined;
        components.minute = NSDateComponentUndefined;
        components.second = NSDateComponentUndefined;
    }
    components.calendar = calendar;
    components.timeZone = zone;
    return components;
}

static NSDictionary *reminder_due_dict(NSDateComponents *components) {
    NSCalendar *calendar = [components.calendar copy] ?: [NSCalendar currentCalendar];
    if (components.timeZone) calendar.timeZone = components.timeZone;
    NSDate *due = components ? [calendar dateFromComponents:components] : nil;
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    formatter.timeZone = calendar.timeZone;
    id (^number)(NSInteger) = ^id(NSInteger value) { return value == NSDateComponentUndefined ? [NSNull null] : @(value); };
    return @{
        @"due": due ? [formatter stringFromDate:due] : [NSNull null],
        @"due_has_time": @(components && components.hour != NSDateComponentUndefined),
        @"timezone": components.timeZone.name ?: components.calendar.timeZone.name ?: [NSNull null],
        @"due_components": components ? @{
            @"calendar": components.calendar.calendarIdentifier ?: [NSNull null],
            @"year": number(components.year), @"month": number(components.month), @"day": number(components.day),
            @"hour": number(components.hour), @"minute": number(components.minute), @"second": number(components.second),
            @"nanosecond": number(components.nanosecond),
        } : [NSNull null],
    };
}
