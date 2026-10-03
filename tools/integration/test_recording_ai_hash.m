#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "recording_ai_canonical_reference.h"
#include <math.h>

// Host-only draft vectors. This is not an EventKit or native offload test.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        NSArray *vectors = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (error || ![vectors isKindOfClass:NSArray.class]) return 2;
        for (NSDictionary *vector in vectors) {
            id value = vector[@"value"];
            if (vector[@"valueUTF16"]) {
                NSArray *units = vector[@"valueUTF16"];
                NSMutableData *characters = [NSMutableData dataWithLength:units.count * sizeof(unichar)];
                unichar *raw = characters.mutableBytes;
                for (NSUInteger i = 0; i < units.count; i++) raw[i] = [units[i] unsignedShortValue];
                value = [[NSString alloc] initWithCharacters:raw length:units.count];
            } else if (vector[@"valueNumber"]) {
                NSString *number = vector[@"valueNumber"];
                if ([number isEqual:@"nan"]) value = @(NAN);
                else if ([number isEqual:@"positiveInfinity"]) value = @(INFINITY);
                else if ([number isEqual:@"negativeInfinity"]) value = @(-INFINITY);
                else return 2;
            }
            NSData *bytes = VCReferenceCanonicalBytes(value, &error);
            if (vector[@"errorCode"]) {
                if (bytes || ![error.userInfo[@"errorCode"] isEqual:vector[@"errorCode"]]) {
                    NSLog(@"canonical rejection differs: %@ (%@)", vector[@"name"], error);
                    return 1;
                }
                continue;
            }
            if (error || ![bytes isEqual:[vector[@"canonicalUTF8"] dataUsingEncoding:NSUTF8StringEncoding]]) {
                NSLog(@"canonical bytes differ: %@", vector[@"name"]);
                return 1;
            }
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
            NSMutableString *hash = [NSMutableString string];
            for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hash appendFormat:@"%02x", digest[i]];
            if (![hash isEqual:vector[@"sha256"]]) return 1;
        }
        printf("PASS: Objective-C reference/CommonCrypto %lu draft hash vectors; not production codec\n", (unsigned long)vectors.count);
    }
    return 0;
}
