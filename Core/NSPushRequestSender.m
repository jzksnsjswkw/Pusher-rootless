#import "NSPushRequestSender.h"
#import "NSPushConstants.h"
#import "NSPushRequest.h"
#import "../helpers.h"
#import "NSPushLog.h"
#import "NSPushSupport.h"
#import <UIKit/UIKit.h>

@interface NSPushRequestSender ()
@property(nonatomic, strong) NSMutableDictionary* retriesLeft;
- (void)sendAttemptWithRequest:(NSPushRequest*)pushRequest
                     logString:(NSString*)logString
                       service:(NSString*)service
                      bulletin:(BBBulletin*)bulletin;
- (NSNumber*)retriesLeftForRetryKey:(NSString*)retryKey;
- (void)setRetriesLeft:(NSNumber*)count forRetryKey:(NSString*)retryKey;
@end

static NSString* retryKeyForBulletinAndService(BBBulletin* bulletin,
                                               NSString* service) {
  return XStr(@"%@_%@_%@", bulletin.bulletinID ?: @"empty_bulletin_id",
              bulletin.sectionID, service);
}

@implementation NSPushRequestSender

+ (instancetype)sharedInstance {
  static NSPushRequestSender* sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [self new];
  });
  return sharedInstance;
}

- (instancetype)init {
  if (self = [super init]) {
    _retriesLeft = [NSMutableDictionary new];
  }
  return self;
}

// retriesLeft is read/written from both the main thread and NSURLSession's
// background completion queues; all access must go through these locked
// accessors to avoid a data race on the mutable dictionary.
- (NSNumber*)retriesLeftForRetryKey:(NSString*)retryKey {
  @synchronized(self) {
    return self.retriesLeft[retryKey];
  }
}

- (void)setRetriesLeft:(NSNumber*)count forRetryKey:(NSString*)retryKey {
  @synchronized(self) {
    if (count) {
      self.retriesLeft[retryKey] = count;
    } else {
      [self.retriesLeft removeObjectForKey:retryKey];
    }
  }
}

- (void)sendRequest:(NSPushRequest*)pushRequest
          logString:(NSString*)logString
            service:(NSString*)service
           bulletin:(BBBulletin*)bulletin {
  NSString* retryKey = retryKeyForBulletinAndService(bulletin, service);
  [self setRetriesLeft:@(PUSHER_TRIES - 1) forRetryKey:retryKey];
  [self sendAttemptWithRequest:pushRequest
                     logString:logString
                       service:service
                      bulletin:bulletin];
}

- (void)sendAttemptWithRequest:(NSPushRequest*)pushRequest
                     logString:(NSString*)logString
                       service:(NSString*)service
                      bulletin:(BBBulletin*)bulletin {
  NSMutableDictionary* infoDictForRequest = [pushRequest.infoDict mutableCopy];
  if (infoDictForRequest[@"imageShrinkFactor"]) {
    [infoDictForRequest removeObjectForKey:@"imageShrinkFactor"];
  }

  NSString* newUrlString = [pushRequest.urlString copy];

  if (infoDictForRequest[@"image"] &&
      [infoDictForRequest[@"image"] isKindOfClass:UIImage.class]) {
    infoDictForRequest[@"image"] =
        [NSPushImage base64RepresentationForImage:infoDictForRequest[@"image"]];
  }

  if ([pushRequest.method caseInsensitiveCompare:@"GET"] == NSOrderedSame) {
    // Only unreserved RFC 3986 characters are left unescaped so that
    // '&', '=', '+', '#', '?', '/' etc. in keys/values can't corrupt the
    // query string.
    static NSCharacterSet* queryAllowedCharacterSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      queryAllowedCharacterSet = [NSCharacterSet
          characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"
                                             @"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                             @"0123456789"
                                             @"-._~"];
    });
    NSString* parameterString = @"";
    for (NSString* key in infoDictForRequest.allKeys) {
      // GET URLs can't carry non-string values (NSNumber, the image marker
      // @YES, etc.) as-is; stringify them so they survive in the query.
      id rawValue = infoDictForRequest[key];
      NSString* value;
      if ([rawValue isKindOfClass:NSString.class]) {
        value = (NSString*)rawValue;
      } else if ([rawValue respondsToSelector:@selector(stringValue)]) {
        value = [rawValue stringValue];
      } else if (rawValue) {
        value = [rawValue description];
      } else {
        value = @"";
      }
      NSString* escapedKey =
          [key stringByAddingPercentEncodingWithAllowedCharacters:
                   queryAllowedCharacterSet];
      NSString* escapedValue =
          [value stringByAddingPercentEncodingWithAllowedCharacters:
                     queryAllowedCharacterSet];
      parameterString = XStr(@"%@%@%@=%@", parameterString,
                             (parameterString.length < 1 ? @"" : @"&"),
                             escapedKey, escapedValue);
    }
    // Don't add a duplicate '?' if the URL template already contains one
    // (custom services can provide full URLs with a query string).
    if (parameterString.length > 0) {
      newUrlString =
          XStr(@"%@%@%@", newUrlString,
               [newUrlString containsString:@"?"] ? @"&" : @"?", parameterString);
    }
    XLog(@"URL String: %@", newUrlString);
  }

  newUrlString = [newUrlString
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  [NSPushLog addToLogIfEnabledForService:service
                                bulletin:bulletin
                                   label:@"URL"
                                  object:newUrlString];
  NSURL* requestURL = [NSURL URLWithString:newUrlString];
  if (!requestURL) {
    XLog(@"Invalid URL: %@", newUrlString);
    [NSPushLog addToLogIfEnabledForService:service
                                  bulletin:bulletin
                                     label:@"Invalid URL"
                                    object:nil];
    // Clear the retry key so a bad URL doesn't leak an entry in the
    // long-running SpringBoard process (it would otherwise grow unbounded).
    [self setRetriesLeft:nil forRetryKey:retryKeyForBulletinAndService(bulletin, service)];
    return;
  }
  NSMutableURLRequest* request =
      [NSMutableURLRequest requestWithURL:requestURL
                              cachePolicy:NSURLRequestUseProtocolCachePolicy
                          timeoutInterval:10];

  [NSPushLog addToLogIfEnabledForService:service
                                bulletin:bulletin
                                   label:@"Method"
                                  object:pushRequest.method];
  [request setHTTPMethod:pushRequest.method];
  for (NSString* headerName in pushRequest.headers) {
    [request setValue:pushRequest.headers[headerName] forHTTPHeaderField:headerName];
    [NSPushLog addToLogIfEnabledForService:service
                                  bulletin:bulletin
                                     label:@"Header"
                                    object:XStr(@"%@: %@", headerName,
                                                pushRequest.headers[headerName])];
  }

  if (XEq(pushRequest.method, @"POST")) {
    // replace image strings with shorter string
    NSMutableDictionary* infoDictForLog = [infoDictForRequest mutableCopy];
    for (NSString* prop in PUSHER_LOG_IMAGE_DATA_PROPERTIES) {
      if (infoDictForLog[prop]) {
        infoDictForLog[prop] = PUSHER_LOG_IMAGE_DATA_REPLACEMENT;
      }
    }
    [NSPushLog addToLogIfEnabledForService:service
                                  bulletin:bulletin
                                     label:@"Request Body Dictionary"
                                    object:infoDictForLog];

    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSError* jsonError = nil;
    NSData* requestData =
        [NSJSONSerialization dataWithJSONObject:infoDictForRequest
                                        options:NSJSONWritingPrettyPrinted
                                          error:&jsonError];
    if (!requestData) {
      XLog(@"%@ JSON serialization failed: %@", logString, jsonError);
      [NSPushLog addToLogIfEnabledForService:service
                                    bulletin:bulletin
                                       label:@"JSON Serialization Error"
                                      object:jsonError.description
                                dontTruncate:YES];
      [self setRetriesLeft:nil
               forRetryKey:retryKeyForBulletinAndService(bulletin, service)];
      return;
    }
    [request setValue:XStr(@"%d", (int)requestData.length)
        forHTTPHeaderField:@"Content-Length"];
    [request setHTTPBody:requestData];
  }

  // use async way to connect network
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          XLog(@"%@ Got response back", logString);

          NSString* retryKey = retryKeyForBulletinAndService(bulletin, service);
          NSNumber* retriesLeft = [self retriesLeftForRetryKey:retryKey];

          if (error == nil) {
            // A body-less success (e.g. 204 or an empty 200) is still a
            // successful response, so don't treat it as a failure here.
            NSString* dataStr =
                [[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding];
            // if has retries left request entity too large and has base64
            // image string (not image set to true)
            UIImage* image = pushRequest.infoDict[@"image"];
            if (image &&
                [dataStr.lowercaseString
                    containsString:@"request entity too large"] &&
                retriesLeft && retriesLeft.intValue > 0 &&
                [image isKindOfClass:UIImage.class]) {
              [self setRetriesLeft:@(retriesLeft.intValue - 1)
                       forRetryKey:retryKey];
              NSMutableDictionary* retryInfoDict = [pushRequest.infoDict mutableCopy];

              CGFloat imageShrinkFactor =
                  ((NSNumber*)pushRequest.infoDict[@"imageShrinkFactor"]
                       ?: @(PUSHER_DEFAULT_SHRINK_FACTOR))
                      .floatValue;
              NSString* status =
                  @"unchanged (your shrink factor may be less than 1.0)";
              // if last retry and has image, set image property to true
              // instead of image base64
              if ([self retriesLeftForRetryKey:retryKey].intValue == 0 ||
                  imageShrinkFactor <= 1.0) {
                // A shrink factor that can't shrink is as good as no shrink;
                // drop the image so we don't re-send the same oversized
                // payload until retries run out.
                status = @"removed";
                retryInfoDict[@"image"] = @YES;
              } else if (imageShrinkFactor > 1.0) {
                status = @"shrunk";
                UIImage* smallerImage =
                    [NSPushImage shrinkImage:image byFactor:imageShrinkFactor];
                retryInfoDict[@"image"] = smallerImage;
              }

              NSString* sizeString = @"";
              if ([retryInfoDict[@"image"] isKindOfClass:UIImage.class]) {
                sizeString =
                    XStr(@" (size: %@)",
                         NSStringFromCGSize(
                             ((UIImage*)retryInfoDict[@"image"]).size));
              }

              XLog(@"%@ Retrying. Try %d of %d with image %@%@. Success but "
                   @"response was %@.",
                   logString, PUSHER_TRIES - (retriesLeft.intValue - 1),
                   PUSHER_TRIES, status, sizeString, dataStr);
              [NSPushLog
                  addToLogIfEnabledForService:service
                                     bulletin:bulletin
                                        label:
                                            XStr(
                                                @"----- Retrying. Try %d of %d "
                                                @"with image %@%@. Network "
                                                @"Response: Success, but "
                                                @"response was %@. -----",
                                                PUSHER_TRIES -
                                                    (retriesLeft.intValue - 1),
                                                PUSHER_TRIES, status,
                                                sizeString, dataStr)
                                       object:nil];

              // give delay so server doesn't get mad at us
              dispatch_time_t delayTime = dispatch_time(
                  DISPATCH_TIME_NOW,
                  (int64_t)(PUSHER_DELAY_BETWEEN_RETRIES * NSEC_PER_SEC));
              dispatch_after(delayTime, dispatch_get_main_queue(), ^(void) {
                [self sendAttemptWithRequest:
                          [NSPushRequest
                              requestWithURLString:pushRequest.urlString
                                           headers:pushRequest.headers
                                          infoDict:retryInfoDict
                                            method:pushRequest.method]
                                    logString:logString
                                      service:service
                                     bulletin:bulletin];
              });
              return;
            }
            if (image && [dataStr.lowercaseString
                             containsString:@"request entity too large"]) {
              // Final attempt: retries are exhausted and the payload is still
              // too large even after dropping the image. Log an honest failure
              // instead of a misleading "Success".
              [NSPushLog addToLogIfEnabledForService:service
                                            bulletin:bulletin
                                               label:@"Network Response: "
                                                     @"Image too large on "
                                                     @"final attempt"
                                              object:dataStr];
              XLog(@"%@ Failed: image too large after final attempt: %@",
                   logString, dataStr);
              [self setRetriesLeft:nil forRetryKey:retryKey];
              return;
            }
            [NSPushLog addToLogIfEnabledForService:service
                                          bulletin:bulletin
                                             label:@"Network Response: Success"
                                            object:dataStr];
            XLog(@"%@ Success: %@", logString, dataStr);
            [self setRetriesLeft:nil forRetryKey:retryKey];
          } else {
            if (error) {
              [NSPushLog addToLogIfEnabledForService:service
                                            bulletin:bulletin
                                               label:@"Network Response: Error"
                                              object:error.description
                                        dontTruncate:YES];
              XLog(@"%@ Error: %@", logString, error);
            } else {
              [NSPushLog
                  addToLogIfEnabledForService:service
                                     bulletin:bulletin
                                        label:@"Network Response: No Data"
                                       object:nil];
              XLog(@"%@ No data", logString);
            }
            if (retriesLeft) {
              if (retriesLeft.intValue > 0) {
                [self setRetriesLeft:@(retriesLeft.intValue - 1)
                         forRetryKey:retryKey];

                NSMutableDictionary* retryInfoDict = [pushRequest.infoDict mutableCopy];
                // NOTE: unlike the "request entity too large" path below, a
                // transport-level error says nothing about the payload size,
                // so retry with the image intact rather than dropping it.

                XLog(@"%@ ----- Retrying. Try %d of %d -----", logString,
                     PUSHER_TRIES - (retriesLeft.intValue - 1), PUSHER_TRIES);
                [NSPushLog
                    addToLogIfEnabledForService:service
                                       bulletin:bulletin
                                          label:
                                              XStr(@"----- Retrying. Try %d of "
                                                   @"%d -----",
                                                   PUSHER_TRIES -
                                                       (retriesLeft.intValue -
                                                        1),
                                                   PUSHER_TRIES)
                                         object:nil];

                // give delay so server doesn't get mad at us
                dispatch_time_t delayTime = dispatch_time(
                    DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC));
                dispatch_after(delayTime, dispatch_get_main_queue(), ^(void) {
                  [self sendAttemptWithRequest:
                            [NSPushRequest
                                requestWithURLString:pushRequest.urlString
                                             headers:pushRequest.headers
                                            infoDict:retryInfoDict
                                              method:pushRequest.method]
                                      logString:logString
                                        service:service
                                       bulletin:bulletin];
                });
              } else {
                // Retries exhausted with no successful response: log an honest
                // final failure instead of silently clearing the retry state.
                [NSPushLog addToLogIfEnabledForService:service
                                              bulletin:bulletin
                                                 label:@"Network Response: "
                                                       @"Failed after all "
                                                       @"retries"
                                                object:error.description
                                          dontTruncate:YES];
                XLog(@"%@ Failed after all retries: %@", logString, error);
                [self setRetriesLeft:nil forRetryKey:retryKey];
              }
            }
          }
        }] resume];
}

@end
