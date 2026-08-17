#import "NSPushRequestSender.h"
#import "NSPushConstants.h"
#import "NSPushRequest.h"
#import "../helpers.h"
#import "NSPushLog.h"
#import "NSPushSupport.h"
#import <UIKit/UIKit.h>

static NSString* NSPushStringForValue(id value) {
  if ([value isKindOfClass:NSString.class]) {
    return (NSString*)value;
  }
  if ([value respondsToSelector:@selector(stringValue)]) {
    return [value stringValue];
  }
  if (value) {
    return [value description];
  }
  return @"";
}

static NSString* NSPushFormEncodedStringFromDictionary(NSDictionary* dictionary) {
  NSCharacterSet* allowed = [NSCharacterSet
      characterSetWithCharactersInString:
          @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
  NSMutableArray* parts = [NSMutableArray array];
  for (id key in dictionary.allKeys) {
    if (![key isKindOfClass:NSString.class]) {
      continue;
    }
    NSString* encodedKey = [[(NSString*)key
        stringByAddingPercentEncodingWithAllowedCharacters:allowed]
        stringByReplacingOccurrencesOfString:@"%20"
                                  withString:@"+"];
    NSString* encodedValue = [[NSPushStringForValue(dictionary[key])
        stringByAddingPercentEncodingWithAllowedCharacters:allowed]
        stringByReplacingOccurrencesOfString:@"%20"
                                  withString:@"+"];
    [parts addObject:[NSString stringWithFormat:@"%@=%@", encodedKey,
                                                encodedValue]];
  }
  return [parts componentsJoinedByString:@"&"];
}

@interface NSPushRequestSender ()
@property(nonatomic, strong) NSMutableDictionary* retriesLeft;
- (void)sendAttemptWithRequest:(NSPushRequest*)pushRequest
                     logString:(NSString*)logString
                       service:(NSString*)service
                      bulletin:(BBBulletin*)bulletin;
- (void)handleResponseForRequest:(NSPushRequest*)pushRequest
                            data:(NSData*)data
                        response:(NSURLResponse*)response
                           error:(NSError*)error
                       logString:(NSString*)logString
                         service:(NSString*)service
                        bulletin:(BBBulletin*)bulletin;
- (NSNumber*)retriesLeftForRetryKey:(NSString*)retryKey;
- (void)setRetriesLeft:(NSNumber*)count forRetryKey:(NSString*)retryKey;
- (NSInteger)decrementRetriesLeftForRetryKey:(NSString*)retryKey;
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

// Atomically claims one retry. Returns the remaining retry count, or -1 when
// there are no retries left to claim.
- (NSInteger)decrementRetriesLeftForRetryKey:(NSString*)retryKey {
  @synchronized(self) {
    NSNumber* current = self.retriesLeft[retryKey];
    if (current && current.integerValue > 0) {
      NSInteger remaining = current.integerValue - 1;
      self.retriesLeft[retryKey] = @(remaining);
      return remaining;
    }
    return -1;
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

  NSString* httpMethod = pushRequest.method.length > 0 ? pushRequest.method : @"POST";
  BOOL isGetOrHead = httpMethod.length > 0 &&
                     ([httpMethod caseInsensitiveCompare:@"GET"] ==
                          NSOrderedSame ||
                      [httpMethod caseInsensitiveCompare:@"HEAD"] ==
                          NSOrderedSame);
  if (isGetOrHead) {
    // Use NSURLComponents + NSURLQueryItem instead of manual string
    // concatenation: it percent-encodes both names and values, preserves any
    // existing query string, and correctly handles '?', '&', and '#'.
    NSURLComponents* components =
        [NSURLComponents componentsWithString:newUrlString];
    if (components) {
      NSMutableArray* queryItems =
          [NSMutableArray arrayWithArray:components.queryItems ?: @[]];
      for (NSString* key in infoDictForRequest.allKeys) {
        // GET/HEAD URLs can't carry non-string values (NSNumber, the image
        // marker @YES, etc.) as-is; stringify them so they survive in the
        // query.
        [queryItems addObject:[NSURLQueryItem queryItemWithName:key
                                                          value:NSPushStringForValue(
                                                                    infoDictForRequest
                                                                        [key])]];
      }
      components.queryItems = queryItems;
      newUrlString = components.string;
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
                                  object:httpMethod];
  [request setHTTPMethod:httpMethod];
  for (NSString* headerName in pushRequest.headers) {
    NSString* headerValue =
        XStrDefault(pushRequest.headers[headerName], @"");
    [request setValue:headerValue forHTTPHeaderField:headerName];
    [NSPushLog addToLogIfEnabledForService:service
                                  bulletin:bulletin
                                     label:@"Header"
                                    object:XStr(@"%@: %@", headerName,
                                                headerValue)];
  }

  if (!isGetOrHead) {
    // Services provide a sanitized log body via logInfoDict. The sender only
    // logs what the service gave it and does not rewrite request bodies.
    NSDictionary* infoDictForLog = pushRequest.logInfoDict ?: infoDictForRequest;
    [NSPushLog addToLogIfEnabledForService:service
                                  bulletin:bulletin
                                     label:@"Request Body Dictionary"
                                    object:infoDictForLog];

    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSData* requestData = nil;
    BOOL isFormBody = pushRequest.bodyType.length > 0 &&
                      [pushRequest.bodyType caseInsensitiveCompare:@"form"] ==
                          NSOrderedSame;
    if (isFormBody) {
      NSString* formString =
          NSPushFormEncodedStringFromDictionary(infoDictForRequest);
      requestData = [formString dataUsingEncoding:NSUTF8StringEncoding];
      [request setValue:@"application/x-www-form-urlencoded; charset=utf-8"
          forHTTPHeaderField:@"Content-Type"];
    } else {
      [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
      NSError* jsonError = nil;
      requestData =
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

          if (!pushRequest.resendHandler) {
            [self handleResponseForRequest:pushRequest
                                      data:data
                                  response:response
                                     error:error
                                 logString:logString
                                   service:service
                                  bulletin:bulletin];
            return;
          }

          pushRequest.resendHandler(pushRequest, response, data, error,
              ^(NSPushRequest* newRequest, BOOL shouldFail) {
                if (newRequest && !shouldFail) {
                  NSInteger retriesLeft =
                      [self decrementRetriesLeftForRetryKey:retryKey];
                  if (retriesLeft >= 0) {
                    if (!newRequest.resendHandler) {
                      newRequest.resendHandler = pushRequest.resendHandler;
                    }
                    newRequest.resendCount = pushRequest.resendCount + 1;
                    XLog(@"%@ Resending via service callback (attempt %lu)",
                         logString, (unsigned long)newRequest.resendCount + 1);
                    [NSPushLog
                        addToLogIfEnabledForService:service
                                           bulletin:bulletin
                                              label:
                                                  XStr(
                                                      @"----- Resending via "
                                                      @"service callback "
                                                      @"(attempt %lu) -----",
                                                      (unsigned long)
                                                          newRequest.resendCount +
                                                          1)
                                             object:nil];
                    [self sendAttemptWithRequest:newRequest
                                       logString:logString
                                         service:service
                                        bulletin:bulletin];
                  } else {
                    NSString* reason = newRequest.failureReason
                                           ?: pushRequest.failureReason
                                           ?: @"Resend attempts exhausted";
                    [NSPushLog
                        addToLogIfEnabledForService:service
                                           bulletin:bulletin
                                              label:
                                                  @"Network Response: "
                                                  @"Failed after all resend "
                                                  @"attempts"
                                             object:reason];
                    XLog(@"%@ Failed after all resend attempts: %@",
                         logString, reason);
                    [self setRetriesLeft:nil forRetryKey:retryKey];
                  }
                  return;
                }

                if (shouldFail) {
                  NSString* reason = (newRequest.failureReason
                                         ?: pushRequest.failureReason)
                                         ?: @"Resend handler marked request "
                                            @"as failed";
                  [NSPushLog addToLogIfEnabledForService:service
                                                bulletin:bulletin
                                                   label:@"Network Response: "
                                                         @"Failed by resend "
                                                         @"handler"
                                                  object:reason];
                  XLog(@"%@ Failed by resend handler: %@", logString, reason);
                  [self setRetriesLeft:nil forRetryKey:retryKey];
                  return;
                }

                [self handleResponseForRequest:pushRequest
                                          data:data
                                      response:response
                                         error:error
                                     logString:logString
                                       service:service
                                      bulletin:bulletin];
              });
        }] resume];
}


- (void)handleResponseForRequest:(NSPushRequest*)pushRequest
                            data:(NSData*)data
                        response:(NSURLResponse*)response
                           error:(NSError*)error
                       logString:(NSString*)logString
                         service:(NSString*)service
                        bulletin:(BBBulletin*)bulletin {
  NSString* retryKey = retryKeyForBulletinAndService(bulletin, service);

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
        [image isKindOfClass:UIImage.class]) {
      NSInteger retriesLeft =
          [self decrementRetriesLeftForRetryKey:retryKey];
      if (retriesLeft >= 0) {
        NSMutableDictionary* retryInfoDict = [pushRequest.infoDict mutableCopy];

        // Guard the type and numeric content: imageShrinkFactor comes
        // from user prefs, so a non-number or non-numeric string should
        // fall back to the default rather than parsing as 0.
        id shrinkFactorValue = pushRequest.infoDict[@"imageShrinkFactor"];
        CGFloat imageShrinkFactor = PUSHER_DEFAULT_SHRINK_FACTOR;
        if ([shrinkFactorValue isKindOfClass:NSNumber.class]) {
          imageShrinkFactor = [shrinkFactorValue floatValue];
        } else if ([shrinkFactorValue isKindOfClass:NSString.class]) {
          NSString* stringValue = [(NSString*)shrinkFactorValue
              stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
          if (stringValue.length > 0) {
            NSScanner* scanner = [NSScanner scannerWithString:stringValue];
            double scanned = 0.0;
            if ([scanner scanDouble:&scanned] && [scanner isAtEnd]) {
              imageShrinkFactor = (CGFloat)scanned;
            }
          }
        }
        NSString* status =
            @"unchanged (your shrink factor may be less than 1.0)";
        // if last retry and has image, set image property to true
        // instead of image base64
        if (retriesLeft == 0 || imageShrinkFactor <= 1.0) {
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

        NSInteger tryNumber = PUSHER_TRIES - retriesLeft;
        XLog(@"%@ Retrying. Try %d of %d with image %@%@. Success but "
             @"response was %@.",
             logString, (int)tryNumber, PUSHER_TRIES, status, sizeString,
             dataStr);
        [NSPushLog
            addToLogIfEnabledForService:service
                               bulletin:bulletin
                                  label:
                                      XStr(
                                          @"----- Retrying. Try %d of %d "
                                          @"with image %@%@. Network "
                                          @"Response: Success, but "
                                          @"response was %@. -----",
                                          (int)tryNumber, PUSHER_TRIES,
                                          status, sizeString, dataStr)
                                 object:nil];

        // give delay so server doesn't get mad at us
        dispatch_time_t delayTime = dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(PUSHER_DELAY_BETWEEN_RETRIES * NSEC_PER_SEC));
        dispatch_after(delayTime,
                       dispatch_get_global_queue(
                           QOS_CLASS_USER_INITIATED, 0),
                       ^(void) {
          NSPushRequest* retryRequest =
              [NSPushRequest requestWithURLString:pushRequest.urlString
                                          headers:pushRequest.headers
                                         infoDict:retryInfoDict
                                           method:pushRequest.method];
          retryRequest.bodyType = pushRequest.bodyType;
          retryRequest.logInfoDict = pushRequest.logInfoDict;
          retryRequest.resendHandler = pushRequest.resendHandler;
          retryRequest.resendCount = pushRequest.resendCount;
          retryRequest.failureReason = pushRequest.failureReason;
          [self sendAttemptWithRequest:retryRequest
                              logString:logString
                                service:service
                               bulletin:bulletin];
        });
        return;
      }
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
    if ([self retriesLeftForRetryKey:retryKey]) {
      NSInteger retriesLeft =
          [self decrementRetriesLeftForRetryKey:retryKey];
      if (retriesLeft >= 0) {
        NSMutableDictionary* retryInfoDict = [pushRequest.infoDict mutableCopy];
        // NOTE: unlike the "request entity too large" path below, a
        // transport-level error says nothing about the payload size,
        // so retry with the image intact rather than dropping it.

        NSInteger tryNumber = PUSHER_TRIES - retriesLeft;
        XLog(@"%@ ----- Retrying. Try %d of %d -----", logString,
             (int)tryNumber, PUSHER_TRIES);
        [NSPushLog
            addToLogIfEnabledForService:service
                               bulletin:bulletin
                                  label:
                                      XStr(@"----- Retrying. Try %d of "
                                           @"%d -----",
                                           (int)tryNumber, PUSHER_TRIES)
                                 object:nil];

        // give delay so server doesn't get mad at us
        dispatch_time_t delayTime = dispatch_time(
            DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC));
        dispatch_after(delayTime,
                       dispatch_get_global_queue(
                           QOS_CLASS_USER_INITIATED, 0),
                       ^(void) {
          NSPushRequest* retryRequest =
              [NSPushRequest requestWithURLString:pushRequest.urlString
                                          headers:pushRequest.headers
                                         infoDict:retryInfoDict
                                           method:pushRequest.method];
          retryRequest.bodyType = pushRequest.bodyType;
          retryRequest.logInfoDict = pushRequest.logInfoDict;
          retryRequest.resendHandler = pushRequest.resendHandler;
          retryRequest.resendCount = pushRequest.resendCount;
          retryRequest.failureReason = pushRequest.failureReason;
          [self sendAttemptWithRequest:retryRequest
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
}


@end
