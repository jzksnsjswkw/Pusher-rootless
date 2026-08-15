#import "NSPWechatService.h"
#import "../../helpers.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

// Guarded prefs integer accessor: prefs can hold non-NSNumber values, and
// agentID is sent as an NSNumber to the WeChat API. NSNumber and NSString are
// accepted; anything else (including NSNull) falls back to 0.
static NSInteger NSPWechatInteger(id value) {
  if ([value isKindOfClass:NSNumber.class]) {
    return [value integerValue];
  }
  if ([value isKindOfClass:NSString.class]) {
    return [(NSString*)value integerValue];
  }
  return 0;
}

@implementation NSPWechatService

+ (void)load {
  [NSPushServiceManager registerServiceClass:self forName:[self serviceName]];
}

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
    @"corpid" : XStrDefault(servicePrefs[NSPPreferenceServiceCorpidKey], @""),
    @"corpsecret" :
        XStrDefault(servicePrefs[NSPPreferenceServiceCorpsecretKey], @""),
    @"agentID" : @(NSPWechatInteger(
        servicePrefs[NSPPreferenceServiceAgentIDKey])),
    @"touser" : XStrDefault(servicePrefs[NSPPreferenceServiceTouserKey], @"")
  };
}

+ (NSDictionary*)extraCustomAppPrefsForName:(NSString*)name
                                   appPrefs:(NSDictionary*)appPrefs {
  return @{@"touser" : XStrDefault(appPrefs[@"touser"], @"")};
}

+ (void)requestForBulletinContext:(NSPBulletinContext*)context
                           config:(NSPushServiceConfig*)config
                       completion:(void (^)(NSPushRequest* request))completion {
  NSString* touser = XStrDefault(config.rawPrefs[@"touser"], @"");
  // agentid and safe must be integers for the WeChat Work message/send API.
  // Use the guarded accessor so malformed prefs can't crash the send path.
  NSInteger agentIDValue = NSPWechatInteger(config.rawPrefs[@"agentID"]);
  NSDictionary* infoDict = @{
    @"touser" : (touser.length != 0) ? touser : @"@all",
    @"msgtype" : @"text",
    @"agentid" : @(agentIDValue),
    @"text" : @{
      @"content" : XStr(@"%@\n%@", context.title ?: @"", context.message ?: @"")
    },
    @"safe" : @0
  };

  NSString* corpid = XStrDefault(config.rawPrefs[@"corpid"], @"");
  NSString* corpsecret = XStrDefault(config.rawPrefs[@"corpsecret"], @"");
  if (corpid.length == 0 || corpsecret.length == 0) {
    if (completion) {
      // Missing credentials: abort rather than sending a request with an
      // empty URL. Callers treat nil as "failed to build request" and skip
      // the send, matching the token-fetch failure path below.
      completion(nil);
    }
    return;
  }

  NSString* cacheKey = [NSString stringWithFormat:@"%@|%@", corpid, corpsecret];
  BOOL cacheHit = NO;
  NSString* cachedToken = cachedWechatTokenForKey(cacheKey, &cacheHit);
  if (cacheHit) {
    if (completion) {
      completion([NSPushRequest
          requestWithURLString:[[PUSHER_SERVICE_WECHAT_URL
              stringByReplacingOccurrencesOfString:@"REPLACE_DYNAMIC_KEY"
                                        withString:cachedToken] copy]
                       headers:nil
                      infoDict:infoDict]);
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
            id jsonResponse =
                [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:nil];
            if ([jsonResponse isKindOfClass:NSDictionary.class] &&
                [jsonResponse[@"errcode"] isEqual:@(0)]) {
              id accessToken = jsonResponse[@"access_token"];
              if ([accessToken isKindOfClass:NSString.class]) {
                token = (NSString*)accessToken;
              }
            }
          }
          if (token && token.length > 0) {
            cacheWechatTokenForKey(cacheKey, token);
          }
          if (completion) {
            if (!token || token.length == 0) {
              // Failed to obtain an access token (network error or invalid
              // corpid/corpsecret). Abort rather than firing a request with an
              // empty token that is guaranteed to fail server-side; the caller
              // logs this as a failed request and clears the retry state.
              completion(nil);
              return;
            }
            completion([NSPushRequest
                requestWithURLString:[[PUSHER_SERVICE_WECHAT_URL
                    stringByReplacingOccurrencesOfString:@"REPLACE_DYNAMIC_KEY"
                                              withString:token] copy]
                             headers:nil
                            infoDict:infoDict]);
          }
        }];
  [dataTask resume];
}

// WeChat access_token is valid for ~7200 seconds. Cache it so we don't
// re-request (and risk rate-limits) on every notification, and so a failed
// gettoken never poisons the retry path with an empty token.
//
// IMPORTANT: these must be file-scope statics, not function-scope. A
// function-scope static in cachedWechatTokenForKey: and a separate one in
// cacheWechatTokenForKey: would make the writer and reader operate on two
// different dictionaries, so the cache would never hit and every notification
// would trigger a fresh gettoken request.
static NSMutableDictionary* wechatTokenCache = nil;
static NSObject* wechatTokenCacheLock = nil;
static dispatch_once_t wechatTokenCacheOnceToken;

static void wechatTokenCacheInit(void) {
  dispatch_once(&wechatTokenCacheOnceToken, ^{
    wechatTokenCache = [NSMutableDictionary new];
    wechatTokenCacheLock = [NSObject new];
  });
}

static NSString* cachedWechatTokenForKey(NSString* cacheKey, BOOL* hit) {
  wechatTokenCacheInit();
  @synchronized(wechatTokenCacheLock) {
    NSDictionary* entry = wechatTokenCache[cacheKey];
    if (entry && [entry[@"expire"] timeIntervalSinceNow] > 0) {
      *hit = YES;
      return entry[@"token"];
    }
  }
  *hit = NO;
  return nil;
}

static void cacheWechatTokenForKey(NSString* cacheKey, NSString* token) {
  wechatTokenCacheInit();
  if (!token || token.length == 0) {
    return; // never cache an empty/failed token
  }
  // Cache with a small margin below WeChat's 7200s expiry.
  NSDate* expire = [NSDate dateWithTimeIntervalSinceNow:7200 - 60];
  @synchronized(wechatTokenCacheLock) {
    wechatTokenCache[cacheKey] = @{@"token" : token, @"expire" : expire};
  }
}

@end
