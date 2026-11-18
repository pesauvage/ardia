#import <React/RCTBridgeModule.h>
#import <React/RCTURLRequestHandler.h>

#import "ArdiaFaviconStore.h"

@interface ArdiaFaviconRequestHandler : NSObject <RCTURLRequestHandler>
@end

@implementation ArdiaFaviconRequestHandler {
  NSOperationQueue *_queue;
}

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = [NSOperationQueue new];
    _queue.maxConcurrentOperationCount = 4;
    _queue.qualityOfService = NSQualityOfServiceUserInitiated;
  }
  return self;
}

- (void)invalidate {
  [_queue cancelAllOperations];
}

- (BOOL)canHandleRequest:(NSURLRequest *)request {
  return [request.URL.scheme caseInsensitiveCompare:ArdiaFaviconScheme] == NSOrderedSame;
}

- (NSOperation *)sendRequest:(NSURLRequest *)request withDelegate:(id<RCTURLRequestDelegate>)delegate {
  NSBlockOperation *operation = [NSBlockOperation new];
  __weak NSBlockOperation *weak = operation;
  NSURL *url = request.URL;
  [operation addExecutionBlock:^{
    NSBlockOperation *running = weak;
    if (!running || running.cancelled) return;
    NSData *png = [ArdiaFaviconStore pngForURI:url.absoluteString];
    if (!png) {
      NSError *missing = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorResourceUnavailable userInfo:@{NSLocalizedDescriptionKey : @"That icon isn't stored"}];
      return [delegate URLRequest:running didCompleteWithError:missing];
    }
    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:url MIMEType:@"image/png" expectedContentLength:(NSInteger)png.length textEncodingName:nil];
    [delegate URLRequest:running didReceiveResponse:response];
    [delegate URLRequest:running didReceiveData:png];
    [delegate URLRequest:running didCompleteWithError:nil];
  }];
  [_queue addOperation:operation];
  return operation;
}

- (void)cancelRequest:(NSOperation *)operation {
  [operation cancel];
}

@end
