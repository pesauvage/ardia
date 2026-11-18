#import <Foundation/Foundation.h>

#import "../ios/ArdiaFaviconSchemes.h"

#include <cstdio>

static int failures = 0;

static void Expect(bool got, bool want, const char *what) {
  if (got == want) return;
  failures++;
  fprintf(stderr, "FAIL %s: got %d, want %d\n", what, got, want);
}

int main() {
  @autoreleasepool {
    using ardia_favicons::HasNoIcon;
    Expect(HasNoIcon(@"ardia://notes/page"), true, "a plugin page");
    Expect(HasNoIcon(@"ardia://history"), true, "the history page");
    Expect(HasNoIcon(@"ARDIA://Notes/"), true, "a plugin page in capitals");
    Expect(HasNoIcon(@"about:blank"), true, "about:blank");
    Expect(HasNoIcon(@"blob:https://example.com/1"), true, "a blob");
    Expect(HasNoIcon(@"data:text/html,hi"), true, "a data page");
    Expect(HasNoIcon(@"javascript:void(0)"), true, "a javascript address");
    Expect(HasNoIcon(@"ardia-favicon://icon/p/00"), true, "a stored icon is not a page");
    Expect(HasNoIcon(@""), true, "an empty address");
    Expect(HasNoIcon(@"no scheme here"), true, "text with no scheme");
    Expect(HasNoIcon(@"https://ardia.dev/"), false, "a website");
    Expect(HasNoIcon(@"http://localhost:3000/ardia://x"), false, "a website that mentions ardia://");
    Expect(HasNoIcon(@"file:///Users/me/page.html"), false, "a file page");
    Expect(HasNoIcon(@"chrome-extension://abc/options.html"), false, "an extension page");
    NSArray *kept = ardia_favicons::WithIcons(@[ @"ardia://notes/page", @"https://a.test/", @7, @"about:blank", @"https://b.test/" ]);
    Expect([kept isEqualToArray:@[ @"https://a.test/", @"https://b.test/" ]], true, "only pages that can have an icon are looked up");
    Expect(ardia_favicons::WithIcons(@"https://a.test/").count == 0, true, "a list that isn't a list keeps nothing");
  }
  if (failures) return 1;
  printf("favicon schemes: ok\n");
  return 0;
}
