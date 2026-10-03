#import "recording_ai_canonical_reference.h"
#import <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <string.h>

static BOOL VCFail(NSError **error, NSString *name) {
    if (error) *error = [NSError errorWithDomain:@"VoiceContext.ReferenceCanonical" code:1
                                      userInfo:@{@"errorCode": name, NSLocalizedDescriptionKey: name}];
    return NO;
}

static void VCAppendASCII(NSMutableData *output, const char *text) {
    [output appendBytes:text length:strlen(text)];
}

static void VCAppendScalar(NSMutableData *output, uint32_t scalar) {
    uint8_t bytes[4];
    NSUInteger count;
    if (scalar < 0x80) { bytes[0] = scalar; count = 1; }
    else if (scalar < 0x800) {
        bytes[0] = 0xc0 | (scalar >> 6); bytes[1] = 0x80 | (scalar & 0x3f); count = 2;
    } else if (scalar < 0x10000) {
        bytes[0] = 0xe0 | (scalar >> 12); bytes[1] = 0x80 | ((scalar >> 6) & 0x3f);
        bytes[2] = 0x80 | (scalar & 0x3f); count = 3;
    } else {
        bytes[0] = 0xf0 | (scalar >> 18); bytes[1] = 0x80 | ((scalar >> 12) & 0x3f);
        bytes[2] = 0x80 | ((scalar >> 6) & 0x3f); bytes[3] = 0x80 | (scalar & 0x3f); count = 4;
    }
    [output appendBytes:bytes length:count];
}

static NSData *VCExactUTF8(NSString *value, NSError **error) {
    NSMutableData *output = [NSMutableData data];
    for (NSUInteger i = 0; i < value.length; i++) {
        uint32_t scalar = [value characterAtIndex:i];
        if (scalar >= 0xd800 && scalar <= 0xdbff) {
            if (++i >= value.length) { VCFail(error, @"invalidUnicode"); return nil; }
            uint32_t low = [value characterAtIndex:i];
            if (low < 0xdc00 || low > 0xdfff) { VCFail(error, @"invalidUnicode"); return nil; }
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
        } else if (scalar >= 0xdc00 && scalar <= 0xdfff) {
            VCFail(error, @"invalidUnicode"); return nil;
        }
        VCAppendScalar(output, scalar);
    }
    return output;
}

static void VCAppendJSONString(NSMutableData *output, NSData *utf8) {
    static const char hex[] = "0123456789abcdef";
    VCAppendASCII(output, "\"");
    const uint8_t *bytes = utf8.bytes;
    for (NSUInteger i = 0; i < utf8.length; i++) {
        uint8_t byte = bytes[i];
        switch (byte) {
            case '"': VCAppendASCII(output, "\\\""); break;
            case '\\': VCAppendASCII(output, "\\\\"); break;
            case '\b': VCAppendASCII(output, "\\b"); break;
            case '\f': VCAppendASCII(output, "\\f"); break;
            case '\n': VCAppendASCII(output, "\\n"); break;
            case '\r': VCAppendASCII(output, "\\r"); break;
            case '\t': VCAppendASCII(output, "\\t"); break;
            default:
                if (byte < 0x20) {
                    const char escaped[] = {'\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0xf]};
                    [output appendBytes:escaped length:sizeof(escaped)];
                } else [output appendBytes:&byte length:1];
        }
    }
    VCAppendASCII(output, "\"");
}

static BOOL VCAppendNumber(NSMutableData *output, NSNumber *value, NSError **error) {
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        VCAppendASCII(output, value.boolValue ? "true" : "false");
        return YES;
    }
    const char *type = value.objCType;
    if (type[0] && !type[1] && strchr("csilq", type[0])) {
        VCAppendASCII(output, [[NSString stringWithFormat:@"%lld", value.longLongValue] UTF8String]);
        return YES;
    }
    if (type[0] && !type[1] && strchr("CSILQ", type[0])) {
        unsigned long long number = value.unsignedLongLongValue;
        if (number > INT64_MAX) return VCFail(error, @"integerOutsideInt64");
        VCAppendASCII(output, [[NSString stringWithFormat:@"%llu", number] UTF8String]);
        return YES;
    }
    // Foundation may parse a JSON integer below INT64_MIN as NSDecimalNumber.
    // Preserve an exact out-of-range integer diagnostic without accepting
    // decimal/floating representations as supported integers.
    if ([value isKindOfClass:NSDecimalNumber.class]) {
        NSString *text = value.stringValue;
        NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
        NSString *digits = [text hasPrefix:@"-"] ? [text substringFromIndex:1] : text;
        if (digits.length && [digits rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            NSDecimalNumber *decimal = (NSDecimalNumber *)value;
            if ([decimal compare:[NSDecimalNumber decimalNumberWithString:@"-9223372036854775808"]] == NSOrderedAscending ||
                [decimal compare:[NSDecimalNumber decimalNumberWithString:@"9223372036854775807"]] == NSOrderedDescending) {
                return VCFail(error, @"integerOutsideInt64");
            }
        }
    }
    return VCFail(error, @"unsupportedCanonicalType");
}

static BOOL VCAppendValue(NSMutableData *output, id value, NSError **error) {
    if (value == NSNull.null) { VCAppendASCII(output, "null"); return YES; }
    if ([value isKindOfClass:NSString.class]) {
        NSData *utf8 = VCExactUTF8(value, error);
        if (!utf8) return NO;
        VCAppendJSONString(output, utf8);
        return YES;
    }
    if ([value isKindOfClass:NSNumber.class]) return VCAppendNumber(output, value, error);
    if ([value isKindOfClass:NSArray.class]) {
        VCAppendASCII(output, "[");
        BOOL first = YES;
        for (id item in value) {
            if (!first) VCAppendASCII(output, ",");
            first = NO;
            if (!VCAppendValue(output, item, error)) return NO;
        }
        VCAppendASCII(output, "]");
        return YES;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableArray *keys = [NSMutableArray array];
        for (id key in value) {
            if (![key isKindOfClass:NSString.class]) return VCFail(error, @"unsupportedCanonicalType");
            NSData *utf8 = VCExactUTF8(key, error);
            if (!utf8) return NO;
            [keys addObject:@{@"key": key, @"utf8": utf8}];
        }
        [keys sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSData *a = left[@"utf8"], *b = right[@"utf8"];
            // Lexicographic valid UTF-8 byte ordering is Unicode scalar order.
            // No NSString collation, UTF-16 order, or normalization participates.
            NSUInteger length = MIN(a.length, b.length);
            int comparison = length ? memcmp(a.bytes, b.bytes, length) : 0;
            if (comparison) return comparison < 0 ? NSOrderedAscending : NSOrderedDescending;
            return a.length < b.length ? NSOrderedAscending : a.length > b.length ? NSOrderedDescending : NSOrderedSame;
        }];
        VCAppendASCII(output, "{");
        BOOL first = YES;
        for (NSDictionary *entry in keys) {
            if (!first) VCAppendASCII(output, ",");
            first = NO;
            VCAppendJSONString(output, entry[@"utf8"]);
            VCAppendASCII(output, ":");
            if (!VCAppendValue(output, value[entry[@"key"]], error)) return NO;
        }
        VCAppendASCII(output, "}");
        return YES;
    }
    return VCFail(error, @"unsupportedCanonicalType");
}

NSData *VCReferenceCanonicalBytes(id value, NSError **error) {
    if (error) *error = nil;
    NSMutableData *output = [NSMutableData data];
    return VCAppendValue(output, value, error) ? [output copy] : nil;
}
