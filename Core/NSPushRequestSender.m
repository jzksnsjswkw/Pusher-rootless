#import "NSPushRequestSender.h"
#import "../global.h"
#import "../helpers.h"
#import "NSPushImage.h"
#import "NSPushLog.h"
#import <UIKit/UIKit.h>

@interface NSPushRequestSender ()
@property(nonatomic, strong) NSMutableDictionary* retriesLeft;
- (void)sendAttemptWithURLString:(NSString*)urlString
                        infoDict:(NSDictionary*)infoDict
                     credentials:(NSDictionary*)credentials
                      dynamicKey:(NSString*)dynamicKey
                        authType:(PusherAuthorizationType)authType
                          method:(NSString*)method
                       logString:(NSString*)logString
                         service:(NSString*)service
                        bulletin:(BBBulletin*)bulletin;
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

- (void)sendRequestWithURLString:(NSString*)urlString
                        infoDict:(NSDictionary*)infoDict
                     credentials:(NSDictionary*)credentials
                      dynamicKey:(NSString*)dynamicKey
                        authType:(PusherAuthorizationType)authType
                          method:(NSString*)method
                       logString:(NSString*)logString
                         service:(NSString*)service
                        bulletin:(BBBulletin*)bulletin {
  NSString* retryKey = retryKeyForBulletinAndService(bulletin, service);
  self.retriesLeft[retryKey] = @(PUSHER_TRIES - 1);
  [self sendAttemptWithURLString:urlString
                        infoDict:infoDict
                     credentials:credentials
                      dynamicKey:dynamicKey
                        authType:authType
                          method:method
                       logString:logString
                         service:service
                        bulletin:bulletin];
}

- (void)sendAttemptWithURLString:(NSString*)urlString
                        infoDict:(NSDictionary*)infoDict
                     credentials:(NSDictionary*)credentials
                      dynamicKey:(NSString*)dynamicKey
                        authType:(PusherAuthorizationType)authType
                          method:(NSString*)method
                       logString:(NSString*)logString
                         service:(NSString*)service
                        bulletin:(BBBulletin*)bulletin {
  NSMutableDictionary* infoDictForRequest = [infoDict mutableCopy];
  if (infoDictForRequest[@"imageShrinkFactor"]) {
    [infoDictForRequest removeObjectForKey:@"imageShrinkFactor"];
  }

  if (authType == PusherAuthorizationTypeCredentials) {
    [infoDictForRequest addEntriesFromDictionary:credentials];
  }

  NSString* newUrlString = [urlString copy];
  if (authType == PusherAuthorizationTypeReplaceKey) {
    newUrlString =
        [newUrlString stringByReplacingOccurrencesOfString:@"REPLACE_KEY"
                                                withString:credentials[@"key"]];
  }
  if (authType == PusherAuthorizationTypeReplaceDynamicKey) {
    newUrlString = [newUrlString
        stringByReplacingOccurrencesOfString:@"REPLACE_DYNAMIC_KEY"
                                  withString:dynamicKey];
  }

  if (infoDictForRequest[@"image"] &&
      [infoDictForRequest[@"image"] isKindOfClass:UIImage.class]) {
    infoDictForRequest[@"image"] =
        [NSPushImage base64RepresentationForImage:infoDictForRequest[@"image"]];
  }

  if (XEq(method, @"GET")) {
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
      NSString* value = XStrDefault(infoDictForRequest[key], @"");
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
    newUrlString = XStr(@"%@?%@", newUrlString, parameterString);
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
    return;
  }
  NSMutableURLRequest* request =
      [NSMutableURLRequest requestWithURL:requestURL
                              cachePolicy:NSURLRequestUseProtocolCachePolicy
                          timeoutInterval:10];

  [NSPushLog addToLogIfEnabledForService:service
                                bulletin:bulletin
                                   label:@"Method"
                                  object:method];
  [request setHTTPMethod:method];
  if (authType == PusherAuthorizationTypeHeader) {
    [request setValue:credentials[@"value"]
        forHTTPHeaderField:credentials[@"headerName"]];
    [NSPushLog
        addToLogIfEnabledForService:service
                           bulletin:bulletin
                              label:@"Header"
                             object:XStr(@"%@: %@", credentials[@"headerName"],
                                         credentials[@"value"])];
  }

  if (XEq(method, @"POST")) {
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

    NSData* requestData =
        [NSJSONSerialization dataWithJSONObject:infoDictForRequest
                                        options:NSJSONWritingPrettyPrinted
                                          error:nil];
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
          NSNumber* retriesLeft = self.retriesLeft[retryKey];

          if (data.length && error == nil) {
            NSString* dataStr =
                [[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding];
            // if has retries left request entity too large and has base64
            // image string (not image set to true)
            UIImage* image = infoDict[@"image"];
            if (image &&
                [dataStr.lowercaseString
                    containsString:@"request entity too large"] &&
                retriesLeft && retriesLeft.intValue > 0 &&
                [image isKindOfClass:UIImage.class]) {
              self.retriesLeft[retryKey] = @(retriesLeft.intValue - 1);
              NSMutableDictionary* retryInfoDict = [infoDict mutableCopy];

              CGFloat imageShrinkFactor =
                  ((NSNumber*)infoDict[@"imageShrinkFactor"]
                       ?: @(PUSHER_DEFAULT_SHRINK_FACTOR))
                      .floatValue;
              NSString* status =
                  @"unchanged (your shrink factor may be less than 1.0)";
              // if last retry and has image, set image property to true
              // instead of image base64
              if (((NSNumber*)self.retriesLeft[retryKey]).intValue == 0) {
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
                [self sendAttemptWithURLString:urlString
                                      infoDict:retryInfoDict
                                   credentials:credentials
                                    dynamicKey:dynamicKey
                                      authType:authType
                                        method:method
                                     logString:logString
                                       service:service
                                      bulletin:bulletin];
              });
              return;
            }
            [NSPushLog addToLogIfEnabledForService:service
                                          bulletin:bulletin
                                             label:@"Network Response: Success"
                                            object:dataStr];
            XLog(@"%@ Success: %@", logString, dataStr);
            [self.retriesLeft removeObjectForKey:retryKey];
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
                self.retriesLeft[retryKey] = @(retriesLeft.intValue - 1);

                NSMutableDictionary* retryInfoDict = [infoDict mutableCopy];
                // if last retry and has image, set image property to true
                // instead of image base64
                if (retryInfoDict[@"image"] && self.retriesLeft[retryKey] &&
                    ((NSNumber*)self.retriesLeft[retryKey]).intValue == 0) {
                  retryInfoDict[@"image"] = @YES;
                }

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
                  [self sendAttemptWithURLString:urlString
                                        infoDict:retryInfoDict
                                     credentials:credentials
                                      dynamicKey:dynamicKey
                                        authType:authType
                                          method:method
                                       logString:logString
                                         service:service
                                        bulletin:bulletin];
                });
              } else {
                [self.retriesLeft removeObjectForKey:retryKey];
              }
            }
          }
        }] resume];
}

@end
