#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reuses existing Apple handlers directly, without a guest task or shell.
@interface MeetingAppleNativeBridge : NSObject
+ (void)executeCommand:(NSString *)command
             arguments:(NSArray<NSString *> *)arguments
         shouldExecute:(BOOL (^)(void))shouldExecute
            completion:(void (^)(NSString *output, int32_t exitCode))completion;
@end

NS_ASSUME_NONNULL_END
