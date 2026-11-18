#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const ArdiaFaviconScheme;

typedef void (^ArdiaFaviconReply)(NSDictionary<NSString *, id> *_Nullable reply, NSString *_Nullable error);

@interface ArdiaFaviconStore : NSObject
+ (BOOL)holdsURI:(nullable NSString *)uri NS_SWIFT_NAME(holds(_:));
+ (nullable NSString *)uriForPNG:(nullable NSData *)png profile:(nullable NSString *)profile NS_SWIFT_NAME(uri(forPNG:profile:));
+ (nullable NSData *)pngForURI:(nullable NSString *)uri NS_SWIFT_NAME(png(_:));
+ (nullable NSImage *)imageForURI:(nullable NSString *)uri NS_SWIFT_NAME(image(_:));
+ (void)lookUp:(NSString *)args profile:(NSString *)profile completion:(ArdiaFaviconReply)completion NS_SWIFT_NAME(lookUp(_:profile:completion:));
+ (void)set:(NSString *)args profile:(NSString *)profile completion:(ArdiaFaviconReply)completion NS_SWIFT_NAME(set(_:profile:completion:));
+ (void)forgetProfile:(nullable NSString *)profile keeping:(NSArray<NSString *> *)uris NS_SWIFT_NAME(forget(_:keeping:));
+ (NSDictionary<NSString *, NSNumber *> *)takeCounts;
@end

NS_ASSUME_NONNULL_END
