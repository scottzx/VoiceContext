#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Host-only C00 reference encoding. Not an approved or production codec.
/// Accepts NSNull, CFBoolean, signed-Int64-representable integer NSNumber,
/// exact valid NSString, NSArray, and NSDictionary with exact NSString keys.
/// Errors expose unsupportedCanonicalType/integerOutsideInt64/invalidUnicode
/// through NSError.userInfo[@"errorCode"]. JSON parsing is the caller's duty.
FOUNDATION_EXPORT NSData * _Nullable VCReferenceCanonicalBytes(
    id _Nullable value, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
