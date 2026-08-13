#import "NSPWechatService.h"
#import "../../helpers.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

@implementation NSPWechatService

+ (NSString*)serviceName {
  return PUSHER_SERVICE_WECHAT;
}

+ (NSString*)urlForEventName:(NSString*)eventName
                      dbName:(NSString*)dbName
                   serverURL:(NSString*)serverURL {
  return PUSHER_SERVICE_WECHAT_URL;
}

+ (NSDictionary*)extraPrefsForName:(NSString*)name
                      servicePrefs:(NSDictionary*)servicePrefs {
  return @{
    @"corpid" : servicePrefs[NSPPreferenceServiceCorpidKey] ?: @"",
    @"corpsecret" : servicePrefs[NSPPreferenceServiceCorpsecretKey] ?: @"",
    @"agentID" : servicePrefs[NSPPreferenceServiceAgentIDKey] ?: @"",
    @"touser" : servicePrefs[NSPPreferenceServiceTouserKey] ?: @""
  };
}

+ (NSDictionary*)extraCustomAppPrefsForName:(NSString*)name
                                   appPrefs:(NSDictionary*)appPrefs {
  return @{@"touser" : appPrefs[@"touser"] ?: @""};
}

+ (NSDictionary*)infoDictForBulletinContext:(NSPBulletinContext*)context
                                     config:(NSPushServiceConfig*)config {
  NSString* touser = config.rawPrefs[@"touser"];
  // agentid and safe must be integers for the WeChat Work message/send API;
  // strings are rejected with an invalid-parameter error.
  NSNumber* agentid = config.rawPrefs[@"agentID"];
  NSInteger agentIDValue = 0;
  if (agentid) {
    agentIDValue = agentid.integerValue;
  } else if ([config.rawPrefs[@"agentID"] isKindOfClass:NSString.class]) {
    agentIDValue = ((NSString*)config.rawPrefs[@"agentID"]).integerValue;
  }
  return @{
    @"touser" : (touser && [touser length] != 0) ? touser : @"@all",
    @"msgtype" : @"text",
    @"agentid" : @(agentIDValue),
    @"text" : @{
      @"content" : XStr(@"%@\n%@", context.title ?: @"", context.message ?: @"")
    },
    @"safe" : @0
  };
}

// WeChat access_token is valid for ~7200 seconds. Cache it so we don't
// re-request (and risk rate-limits) on every notification, and so a failed
// gettoken never poisons the retry path with an empty token.
static NSString* cachedWechatTokenForKey(NSString* cacheKey, BOOL* hit) {
  static NSMutableDictionary* tokenCache = nil;
  static NSObject* lock = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    tokenCache = [NSMutableDictionary new];
    lock = [NSObject new];
  });
  @synchronized(lock) {
    NSDictionary* entry = tokenCache[cacheKey];
    if (entry && [entry[@"expire"] timeIntervalSinceNow] > 0) {
      *hit = YES;
      return entry[@"token"];
    }
  }
  *hit = NO;
  return nil;
}

static void cacheWechatTokenForKey(NSString* cacheKey, NSString* token) {
  static NSMutableDictionary* tokenCache = nil;
  static NSObject* lock = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    tokenCache = [NSMutableDictionary new];
    lock = [NSObject new];
  });
  if (!token || token.length == 0) {
    return; // never cache an empty/failed token
  }
  // Cache with a small margin below WeChat's 7200s expiry.
  NSDate* expire = [NSDate dateWithTimeIntervalSinceNow:7200 - 60];
  @synchronized(lock) {
    tokenCache[cacheKey] = @{@"token" : token, @"expire" : expire};
  }
}

+ (void)URLStringForConfig:(NSPushServiceConfig*)config
                completion:(void (^)(NSString* urlString))completion {
  NSString* corpid = config.rawPrefs[@"corpid"];
  NSString* corpsecret = config.rawPrefs[@"corpsecret"];
  if (!corpid || !corpsecret) {
    if (completion) {
      completion(@""); // empty URL to avoid nil crash in request creation
    }
    return;
  }

  NSString* cacheKey = [NSString stringWithFormat:@"%@|%@", corpid, corpsecret];
  BOOL cacheHit = NO;
  NSString* cachedToken = cachedWechatTokenForKey(cacheKey, &cacheHit);
  if (cacheHit) {
    if (completion) {
      completion([[PUSHER_SERVICE_WECHAT_URL
          stringByReplacingOccurrencesOfString:@"REPLACE_DYNAMIC_KEY"
                                    withString:cachedToken] copy]);
    }
    return;
  }

  NSString* reqUrl = @"https://qyapi.weixin.qq.com/cgi-bin/gettoken";
  NSDictionary* params = @{@"corpid" : corpid, @"corpsecret" : corpsecret};
  NSMutableArray* queryItems = [NSMutableArray array];
  NSCharacterSet* allowed = [NSCharacterSet
      characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
                                         @"klmnopqrstuvwxyz0123456789-._~"];
  for (NSString* key in params) {
    NSString* encoded = [(NSString*)params[key]
        stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    [queryItems addObject:[NSString stringWithFormat:@"%@=%@", key, encoded]];
  }
  NSString* queryString = [queryItems componentsJoinedByString:@"&"];
  reqUrl = [reqUrl stringByAppendingFormat:@"?%@", queryString];
  NSMutableURLRequest* request =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:reqUrl]];
  [request setHTTPMethod:@"POST"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSURLSession* session = [NSURLSession sharedSession];
  NSURLSessionDataTask* dataTask = [session
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          NSString* token = @"";
          if (!error) {
            NSDictionary* jsonResponse =
                [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:nil];
            if ([jsonResponse[@"errcode"] isEqual:@(0)]) {
              token = jsonResponse[@"access_token"];
            }
          }
          if (token && token.length > 0) {
            cacheWechatTokenForKey(cacheKey, token);
          }
          if (completion) {
            completion([[PUSHER_SERVICE_WECHAT_URL
                stringByReplacingOccurrencesOfString:@"REPLACE_DYNAMIC_KEY"
                                          withString:token ?: @""] copy]);
          }
        }];
  [dataTask resume];
}

@end
