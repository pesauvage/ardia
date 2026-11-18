#import "ArdiaFaviconStore.h"

#import "ArdiaEngineBridge.h"
#import "ArdiaFaviconSchemes.h"
#import "ArdiaInternal.h"
#import "ArdiaRuntime.h"

#import <CommonCrypto/CommonDigest.h>
#import <os/lock.h>

NSString *const ArdiaFaviconScheme = @"ardia-favicon";

namespace {

constexpr NSUInteger kMemoryBytes = 12 * 1024 * 1024;
constexpr NSUInteger kPrivateIcons = 2048;
constexpr NSUInteger kDiskIcons = 6000;
constexpr NSTimeInterval kDiskAge = 45 * 24 * 60 * 60;
constexpr NSTimeInterval kTouchAfter = 24 * 60 * 60;
constexpr NSUInteger kHashLength = 32;

struct Counts {
  long memory = 0;
  long disk = 0;
  long missed = 0;
  long stored = 0;
};

os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
Counts gCounts;

NSCache<NSString *, NSData *> *Memory() {
  static NSCache *cache = [] {
    NSCache *c = [NSCache new];
    c.totalCostLimit = kMemoryBytes;
    return c;
  }();
  return cache;
}

NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSData *> *> *PrivateIcons() {
  static NSMutableDictionary *icons = [NSMutableDictionary dictionary];
  return icons;
}

NSMutableDictionary<NSString *, NSData *> *PendingWrites() {
  static NSMutableDictionary *writes = [NSMutableDictionary dictionary];
  return writes;
}

NSMutableSet<NSString *> *PrunedProfiles() {
  static NSMutableSet *pruned = [NSMutableSet set];
  return pruned;
}

dispatch_queue_t DiskQueue() {
  static dispatch_queue_t queue = dispatch_queue_create("com.ardia.favicons.disk", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
  return queue;
}

dispatch_queue_t WorkQueue() {
  static dispatch_queue_t queue = dispatch_queue_create("com.ardia.favicons.work", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0));
  return queue;
}

NSString *HashOf(NSData *png) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(png.bytes, (CC_LONG)png.length, digest);
  NSMutableString *hex = [NSMutableString stringWithCapacity:kHashLength];
  for (NSUInteger i = 0; i < kHashLength / 2; i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

bool IsHash(NSString *text) {
  if (text.length != kHashLength) return false;
  for (NSUInteger i = 0; i < text.length; i++) {
    const unichar c = [text characterAtIndex:i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}

NSString *URIOf(NSString *profile, NSString *hash) {
  NSString *escaped = [profile stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: @"";
  return [NSString stringWithFormat:@"%@://icon/p%@/%@", ArdiaFaviconScheme, escaped, hash];
}

struct Parsed {
  NSString *profile = nil;
  NSString *hash = nil;
};

Parsed Parse(NSString *uri) {
  NSString *prefix = [ArdiaFaviconScheme stringByAppendingString:@"://icon/"];
  if (![uri hasPrefix:prefix]) return {};
  NSString *rest = [uri substringFromIndex:prefix.length];
  const NSRange query = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
  if (query.location != NSNotFound) rest = [rest substringToIndex:query.location];
  const NSRange slash = [rest rangeOfString:@"/"];
  if (slash.location == NSNotFound) return {};
  NSString *named = [rest substringToIndex:slash.location].stringByRemovingPercentEncoding;
  NSString *hash = [rest substringFromIndex:NSMaxRange(slash)];
  if (![named hasPrefix:@"p"] || !IsHash(hash)) return {};
  return {[named substringFromIndex:1], hash};
}

NSString *Directory(NSString *profile) {
  if ([profile containsString:@"/"] || [profile isEqualToString:@".."] || [profile isEqualToString:@"."]) return nil;
  NSString *dir = ardia_host::ProfileDirectoryName(profile);
  return [[[ArdiaHost.dataDirectory stringByAppendingPathComponent:dir] stringByAppendingPathComponent:@"Ardia Favicons"] stringByAppendingPathComponent:@"cache"];
}

NSString *PathOf(const Parsed &icon) {
  NSString *dir = Directory(icon.profile);
  return dir ? [dir stringByAppendingPathComponent:[icon.hash stringByAppendingPathExtension:@"png"]] : nil;
}

void Prune(NSString *profile) {
  NSString *dir = Directory(profile);
  if (!dir) return;
  NSFileManager *files = NSFileManager.defaultManager;
  NSArray<NSURL *> *all = [files contentsOfDirectoryAtURL:[NSURL fileURLWithPath:dir] includingPropertiesForKeys:@[ NSURLContentModificationDateKey ] options:0 error:nil];
  NSMutableArray<NSArray *> *dated = [NSMutableArray arrayWithCapacity:all.count];
  NSDate *oldest = [NSDate dateWithTimeIntervalSinceNow:-kDiskAge];
  for (NSURL *file in all) {
    NSDate *modified = nil;
    [file getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
    if (!modified || [modified compare:oldest] == NSOrderedAscending) [files removeItemAtURL:file error:nil];
    else [dated addObject:@[ modified, file ]];
  }
  if (dated.count <= kDiskIcons) return;
  [dated sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
    return [a[0] compare:b[0]];
  }];
  for (NSUInteger i = 0; i < dated.count - kDiskIcons; i++) [files removeItemAtURL:dated[i][1] error:nil];
}

void PruneOnce(NSString *profile) {
  os_unfair_lock_lock(&gLock);
  const bool first = ![PrunedProfiles() containsObject:profile];
  if (first) [PrunedProfiles() addObject:profile];
  os_unfair_lock_unlock(&gLock);
  if (first)
    dispatch_async(DiskQueue(), ^{
      Prune(profile);
    });
}

NSString *Keep(NSData *png, NSString *profile, bool isPrivate) {
  if (!png.length) return nil;
  profile = profile ?: @"";
  const Parsed icon = {profile, HashOf(png)};
  NSString *uri = URIOf(profile, icon.hash);
  if (isPrivate) {
    os_unfair_lock_lock(&gLock);
    NSMutableDictionary *icons = PrivateIcons()[profile];
    if (!icons) PrivateIcons()[profile] = icons = [NSMutableDictionary dictionary];
    if (icons.count >= kPrivateIcons && !icons[uri]) [icons removeAllObjects];
    icons[uri] = png;
    gCounts.stored++;
    os_unfair_lock_unlock(&gLock);
    return uri;
  }
  NSString *path = PathOf(icon);
  if (!path) return nil;
  os_unfair_lock_lock(&gLock);
  const bool known = [Memory() objectForKey:uri] || PendingWrites()[uri];
  if (!known) PendingWrites()[uri] = png;
  gCounts.stored++;
  os_unfair_lock_unlock(&gLock);
  [Memory() setObject:png forKey:uri cost:png.length];
  if (known) return uri;
  PruneOnce(profile);
  dispatch_async(DiskQueue(), ^{
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:path]) {
      [files createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
      [png writeToFile:path atomically:YES];
    }
    os_unfair_lock_lock(&gLock);
    [PendingWrites() removeObjectForKey:uri];
    os_unfair_lock_unlock(&gLock);
  });
  return uri;
}

void TouchIfOld(NSString *path) {
  NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
  if (modified && -modified.timeIntervalSinceNow < kTouchAfter) return;
  dispatch_async(DiskQueue(), ^{
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate : NSDate.date} ofItemAtPath:path error:nil];
  });
}

NSData *Bytes(NSString *uri) {
  const Parsed icon = Parse(uri);
  if (!icon.hash) return nil;
  NSData *png = [Memory() objectForKey:uri];
  os_unfair_lock_lock(&gLock);
  if (!png) png = PrivateIcons()[icon.profile][uri] ?: PendingWrites()[uri];
  if (png) gCounts.memory++;
  os_unfair_lock_unlock(&gLock);
  if (png) return png;
  NSString *path = PathOf(icon);
  png = path ? [NSData dataWithContentsOfFile:path] : nil;
  os_unfair_lock_lock(&gLock);
  if (png.length) gCounts.disk++;
  else gCounts.missed++;
  os_unfair_lock_unlock(&gLock);
  if (!png.length) return nil;
  [Memory() setObject:png forKey:uri cost:png.length];
  TouchIfOld(path);
  return png;
}

NSData *Decoded(id base64) {
  return [base64 isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil;
}

NSDictionary *Kept(NSDictionary *found, NSString *profile, bool isPrivate) {
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  if (![found isKindOfClass:NSDictionary.class]) return out;
  for (NSString *key in found) {
    NSDictionary *entry = found[key];
    if (![entry isKindOfClass:NSDictionary.class]) continue;
    NSString *uri = Keep(Decoded(entry[@"png"]), profile, isPrivate);
    if (!uri) continue;
    NSString *icon = entry[@"icon"];
    out[key] = [icon isKindOfClass:NSString.class] ? @{@"uri" : uri, @"icon" : icon} : @{@"uri" : uri};
  }
  return out;
}

NSString *ErrorOf(id reply) {
  if (![reply isKindOfClass:NSDictionary.class]) return @"the engine's reply isn't an object";
  id error = reply[@"error"];
  if (!error) return nil;
  return [error isKindOfClass:NSString.class] ? error : [error description];
}

}

@implementation ArdiaFaviconStore

+ (BOOL)holdsURI:(NSString *)uri {
  return Parse(uri).hash != nil;
}

+ (NSString *)uriForPNG:(NSData *)png profile:(NSString *)profile {
  return Keep(png, profile, ardia_host::IsPrivateProfile(profile));
}

+ (NSData *)pngForURI:(NSString *)uri {
  return uri.length ? Bytes(uri) : nil;
}

+ (NSImage *)imageForURI:(NSString *)uri {
  NSData *png = [self pngForURI:uri];
  return png ? [[NSImage alloc] initWithData:png] : nil;
}

+ (void)lookUp:(NSString *)args profile:(NSString *)profile completion:(ArdiaFaviconReply)completion {
  id asked = ardia_runtime::JSONObject(args);
  if (![asked isKindOfClass:NSDictionary.class]) return completion(nil, @"bad arguments");
  NSArray<NSString *> *pages = ardia_favicons::WithIcons(asked[@"pages"]);
  NSArray<NSString *> *icons = ardia_favicons::WithIcons(asked[@"icons"]);
  if (!pages.count && !icons.count) return completion(@{@"pages" : @{}, @"icons" : @{}}, nil);
  NSMutableDictionary *wanted = [asked mutableCopy];
  wanted[@"pages"] = pages;
  wanted[@"icons"] = icons;
  args = ardia_runtime::JSONText(wanted);
  const bool isPrivate = ardia_host::IsPrivateProfile(profile);
  [ArdiaEngineBridge call:@"ac_favicons_get"
                  profile:profile
                     args:args
               completion:^(NSString *json) {
                 dispatch_async(WorkQueue(), ^{
                   id reply = ardia_runtime::JSONObject(json);
                   NSString *error = ErrorOf(reply);
                   NSDictionary *found = error ? nil : @{
                     @"pages" : Kept(reply[@"pages"], profile, isPrivate),
                     @"icons" : Kept(reply[@"icons"], profile, isPrivate),
                   };
                   dispatch_async(dispatch_get_main_queue(), ^{
                     completion(found, error);
                   });
                 });
               }];
}

+ (void)set:(NSString *)args profile:(NSString *)profile completion:(ArdiaFaviconReply)completion {
  id parsed = ardia_runtime::JSONObject(args);
  if (![parsed isKindOfClass:NSDictionary.class]) return completion(nil, @"bad arguments");
  NSString *page = parsed[@"page"];
  if (![page isKindOfClass:NSString.class] || ardia_favicons::HasNoIcon(page)) return completion(@{@"stored" : @NO}, nil);
  NSData *png = Decoded(parsed[@"png"]);
  NSString *uri = [self uriForPNG:png profile:profile];
  [ArdiaEngineBridge call:@"ac_favicons_set"
                  profile:profile
                     args:args
               completion:^(NSString *json) {
                 id reply = ardia_runtime::JSONObject(json);
                 if (NSString *error = ErrorOf(reply)) return completion(nil, error);
                 NSMutableDictionary *out = [reply mutableCopy];
                 if (uri) out[@"uri"] = uri;
                 completion(out, nil);
               }];
}

+ (void)forgetProfile:(NSString *)profile keeping:(NSArray<NSString *> *)uris {
  profile = profile ?: @"";
  NSMutableSet<NSString *> *keptFiles = [NSMutableSet set];
  NSMutableDictionary<NSString *, NSData *> *keptPrivate = [NSMutableDictionary dictionary];
  os_unfair_lock_lock(&gLock);
  NSDictionary<NSString *, NSData *> *held = PrivateIcons()[profile];
  for (NSString *uri in uris) {
    const Parsed icon = Parse(uri);
    if (!icon.hash || ![icon.profile isEqualToString:profile]) continue;
    [keptFiles addObject:[icon.hash stringByAppendingPathExtension:@"png"]];
    if (NSData *png = held[uri]) keptPrivate[uri] = png;
  }
  if (keptPrivate.count) PrivateIcons()[profile] = keptPrivate;
  else [PrivateIcons() removeObjectForKey:profile];
  os_unfair_lock_unlock(&gLock);
  [Memory() removeAllObjects];
  NSString *dir = Directory(profile);
  if (!dir) return;
  dispatch_async(DiskQueue(), ^{
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *name in [files contentsOfDirectoryAtPath:dir error:nil])
      if (![keptFiles containsObject:name]) [files removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
  });
}

+ (NSDictionary<NSString *, NSNumber *> *)takeCounts {
  os_unfair_lock_lock(&gLock);
  const Counts counts = gCounts;
  gCounts = {};
  os_unfair_lock_unlock(&gLock);
  return @{@"memory" : @(counts.memory), @"disk" : @(counts.disk), @"missed" : @(counts.missed), @"stored" : @(counts.stored)};
}

@end
