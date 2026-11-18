#import <Foundation/Foundation.h>

namespace ardia_favicons {

inline bool HasNoIcon(NSString *url) {
  static NSSet<NSString *> *schemes = [NSSet setWithArray:@[ @"ardia", @"ardia-favicon", @"about", @"blob", @"data", @"javascript" ]];
  const NSRange colon = [url rangeOfString:@":"];
  if (!url.length || colon.location == NSNotFound || colon.location == 0) return true;
  return [schemes containsObject:[url substringToIndex:colon.location].lowercaseString];
}

inline NSArray<NSString *> *WithIcons(id urls) {
  NSMutableArray<NSString *> *kept = [NSMutableArray array];
  if (![urls isKindOfClass:NSArray.class]) return kept;
  for (id url in urls)
    if ([url isKindOfClass:NSString.class] && !HasNoIcon(url)) [kept addObject:url];
  return kept;
}

}
