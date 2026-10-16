#import "MeetingAppleNativeBridge.h"
#import "CalendarOffload.h"
#import "RemindersOffload.h"
#import "LocationOffload.h"
#import "MapsOffload.h"
#import "WeatherOffload.h"
#import "DeviceOffload.h"
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

typedef int (*MeetingNativeHandler)(int, char **, int, int);

static MeetingNativeHandler meeting_handler(NSString *command) {
    if ([command isEqualToString:@"apple-calendar"]) return calendar_offload_execute_direct;
    if ([command isEqualToString:@"apple-reminders"]) return reminders_offload_execute_direct;
    if ([command isEqualToString:@"apple-location"]) return location_offload_execute_direct;
    if ([command isEqualToString:@"apple-maps"]) return maps_offload_execute_direct;
    if ([command isEqualToString:@"apple-weather"]) return weather_offload_execute_direct;
    if ([command isEqualToString:@"apple-device"]) return device_offload_execute_direct;
    return NULL;
}

static int meeting_output_fd(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"meeting-native.XXXXXX"];
    char *template = strdup(path.fileSystemRepresentation);
    int fd = mkstemp(template);
    if (fd >= 0) unlink(template);
    free(template);
    return fd;
}

static NSString *meeting_read_output(int fd, BOOL *truncated) {
    const size_t capacity = 256 * 1024;
    NSMutableData *data = [NSMutableData dataWithLength:capacity + 1];
    lseek(fd, 0, SEEK_SET);
    ssize_t count = read(fd, data.mutableBytes, capacity + 1);
    if (count < 0) return nil;
    *truncated = count > capacity;
    data.length = MIN((size_t)count, capacity);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@implementation MeetingAppleNativeBridge
+ (void)executeCommand:(NSString *)command arguments:(NSArray<NSString *> *)arguments
         shouldExecute:(BOOL (^)(void))shouldExecute
            completion:(void (^)(NSString *, int32_t))completion {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("Yima.MeetingAppleNative", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(queue, ^{
        @autoreleasepool {
            MeetingNativeHandler handler = meeting_handler(command);
            if (!handler || arguments.count > 80 || !shouldExecute()) {
                completion(@"Native command unavailable or request cancelled; nothing executed.", 1);
                return;
            }
            int outFD = meeting_output_fd(), errFD = meeting_output_fd();
            if (outFD < 0 || errFD < 0) {
                if (outFD >= 0) close(outFD);
                if (errFD >= 0) close(errFD);
                completion(@"Could not prepare native result storage; nothing executed.", 1);
                return;
            }
            NSArray<NSString *> *tokens = [@[command] arrayByAddingObjectsFromArray:arguments];
            char **argv = calloc(tokens.count + 1, sizeof(char *));
            for (NSUInteger i = 0; i < tokens.count; i++) argv[i] = strdup(tokens[i].UTF8String);
            BOOL invoked = shouldExecute();
            int code = invoked ? handler((int)tokens.count, argv, outFD, errFD) : 1;
            for (NSUInteger i = 0; i < tokens.count; i++) free(argv[i]);
            free(argv);
            BOOL truncated = NO, errorTruncated = NO;
            NSString *output = meeting_read_output(outFD, &truncated);
            NSString *error = meeting_read_output(errFD, &errorTruncated);
            close(outFD); close(errFD);
            if (!invoked) {
                completion(@"Meeting request cancelled; nothing executed.", 1);
            } else if (!output || !error) {
                completion(@"Could not read the native receipt. Check the actual result before repeating a mutation.", 1);
            } else if (truncated || errorTruncated) {
                completion(@"Native result exceeded 256 KiB. Query a smaller range; do not repeat a mutation without checking its result.", 1);
            } else {
                completion(output.length ? output : error, code);
            }
        }
    });
}
@end
