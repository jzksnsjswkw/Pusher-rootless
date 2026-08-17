#import "NSPWechatService.h"
#import "../../helpers.h"
#import "../NSPushConfig.h"
#import "../NSPushSupport.h"

@interface NSPWechatService ()
+ (void)fetchAccessTokenWithCorpid:(NSString*)corpid
                        corpsecret:(NSString*)corpsecret
                  invalidatingToken:(NSString*)invalidatingToken
                        completion:(void (^)(NSString* token,
                                             NSInteger expiresIn))completion;
+ (NSPushRequest*)wechatPushRequestWithToken:(NSString*)token
                                   infoDict:(NSDictionary*)infoDict
                                    cacheKey:(NSString*)cacheKey
                                     corpid:(NSString*)corpid
                                   corpsecret:(NSString*)corpsecret;
@end

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
    @"agentID" : @(NSPushIntegerValue(
        servicePrefs[NSPPreferenceServiceAgentIDKey], 0)),
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
  NSInteger agentIDValue = NSPushIntegerValue(config.rawPrefs[@"agentID"], 0);
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
      NSPushRequest* request =
          [self wechatPushRequestWithToken:cachedToken
                                  infoDict:infoDict
                                   cacheKey:cacheKey
                                    corpid:corpid
                                  corpsecret:corpsecret];
      completion(request);
    }
    return;
  }

  [self fetchAccessTokenWithCorpid:corpid
                        corpsecret:corpsecret
                  invalidatingToken:nil
                        completion:^(NSString* token, NSInteger expiresIn) {
      if (completion) {
        if (!token || token.length == 0) {
          // Failed to obtain an access token (network error or invalid
          // corpid/corpsecret). Abort rather than firing a request with an
          // empty token that is guaranteed to fail server-side; the caller
          // logs this as a failed request and clears the retry state.
          completion(nil);
          return;
        }
        // fetchAccessTokenWithCorpid:already cached the token before invoking
        // this completion, so no need to write the cache again here.
        NSPushRequest* request =
            [self wechatPushRequestWithToken:token
                                    infoDict:infoDict
                                     cacheKey:cacheKey
                                      corpid:corpid
                                    corpsecret:corpsecret];
        completion(request);
      }
    }];
}

+ (void)fetchAccessTokenWithCorpid:(NSString*)corpid
                        corpsecret:(NSString*)corpsecret
                  invalidatingToken:(NSString*)invalidatingToken
                        completion:(void (^)(NSString* token,
                                             NSInteger expiresIn))completion {
  if (!completion) {
    return;
  }

  wechatTokenCacheInit();
  NSString* cacheKey = [NSString stringWithFormat:@"%@|%@", corpid, corpsecret];

  // The cache lookup, stale-token invalidation, and single-flight registration
  // must happen in one critical section. Otherwise a fetch that completes
  // between "cache miss" and "register pending" can cause a duplicate gettoken,
  // and a delayed refresh can delete a token that a concurrent fetch just wrote.
  NSString* cachedToken = nil;
  NSInteger cachedExpiresIn = 7200;
  BOOL shouldStartFetch = NO;

  @synchronized(wechatTokenCacheLock) {
    NSDictionary* entry = wechatTokenCache[cacheKey];
    NSDate* expireDate = entry[@"expire"];
    if (entry && [expireDate isKindOfClass:NSDate.class] &&
        [expireDate timeIntervalSinceNow] > 0) {
      NSString* currentToken = entry[@"token"];
      // For a refresh, only ignore/replace the cache if it still holds the exact
      // token that was rejected. If another fetch already refreshed to a
      // different token, use that fresh token instead of starting another fetch.
      if (invalidatingToken.length == 0 ||
          ![currentToken isEqualToString:invalidatingToken]) {
        cachedToken = currentToken;
        // Report the same expiresIn semantics as the network fetch path (the
        // server's total expires_in, stored verbatim at cache time). Returning
        // a "remaining lifetime" here would make the two paths inconsistent.
        id expiresInValue = entry[@"expiresIn"];
        if ([expiresInValue isKindOfClass:NSNumber.class]) {
          cachedExpiresIn = [expiresInValue integerValue];
        }
      } else {
        [wechatTokenCache removeObjectForKey:cacheKey];
      }
    } else if (entry) {
      // Drop expired/stale entries so they don't linger.
      [wechatTokenCache removeObjectForKey:cacheKey];
    }

    if (!cachedToken) {
      NSMutableArray* pending = wechatPendingFetches[cacheKey];
      if (pending) {
        [pending addObject:[completion copy]];
      } else {
        pending = [NSMutableArray arrayWithObject:[completion copy]];
        wechatPendingFetches[cacheKey] = pending;
        shouldStartFetch = YES;
      }
    }
  }

  if (cachedToken) {
    completion(cachedToken, cachedExpiresIn);
    return;
  }
  if (!shouldStartFetch) {
    // Joined an in-flight fetch; its completion will notify this caller.
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
  [request setHTTPMethod:@"GET"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  // Don't let a single hung gettoken block every pending caller for that
  // corpid|corpsecret indefinitely.
  request.timeoutInterval = 15.0;
  NSURLSession* session = [NSURLSession sharedSession];
  NSURLSessionDataTask* dataTask = [session
      dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response,
                            NSError* error) {
          NSString* token = @"";
          NSInteger expiresIn = 7200;
          if (!error) {
            id jsonResponse =
                [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:nil];
            if ([jsonResponse isKindOfClass:NSDictionary.class]) {
              // Only a present, non-zero errcode means failure. WeChat always
              // returns a numeric errcode on the gettoken API, but a missing
              // or NSNull value must not discard a valid access_token: treating
              // it as failure would drop the token, and [NSNull integerValue]
              // would crash.
              id errcodeValue = jsonResponse[@"errcode"];
              NSInteger errcode =
                  [errcodeValue respondsToSelector:@selector(integerValue)]
                      ? [errcodeValue integerValue]
                      : 0;
              if (errcode == 0) {
                id accessToken = jsonResponse[@"access_token"];
                if ([accessToken isKindOfClass:NSString.class]) {
                  token = (NSString*)accessToken;
                }
                id expiresInValue = jsonResponse[@"expires_in"];
                if ([expiresInValue isKindOfClass:NSNumber.class]) {
                  expiresIn = [expiresInValue integerValue];
                } else if ([expiresInValue isKindOfClass:NSString.class]) {
                  expiresIn = [(NSString*)expiresInValue integerValue];
                }
              }
            }
          }

          // Cache and release waiters in one critical section. Doing this
          // atomically prevents a concurrent refresh from observing the new
          // token while the old pending fetch is still registered, which could
          // otherwise let it invalidate the fresh token and then be handed back
          // the same token it wanted to replace.
          NSArray* completions = nil;
          @synchronized(wechatTokenCacheLock) {
            if (token.length > 0) {
              cacheWechatTokenForKey(cacheKey, token, expiresIn);
            }
            completions = [wechatPendingFetches[cacheKey] copy];
            [wechatPendingFetches removeObjectForKey:cacheKey];
          }
          for (void (^callback)(NSString*, NSInteger) in completions) {
            callback((token.length > 0) ? token : nil, expiresIn);
          }
        }];
  [dataTask resume];
}

+ (NSPushRequest*)wechatPushRequestWithToken:(NSString*)token
                                   infoDict:(NSDictionary*)infoDict
                                    cacheKey:(NSString*)cacheKey
                                     corpid:(NSString*)corpid
                                   corpsecret:(NSString*)corpsecret {
  NSCharacterSet* allowed = [NSCharacterSet
      characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
                                         @"klmnopqrstuvwxyz0123456789-._~"];
  NSString* encodedToken = [(token ?: @"")
      stringByAddingPercentEncodingWithAllowedCharacters:allowed];
  NSPushRequest* request = [NSPushRequest
      requestWithURLString:[[PUSHER_SERVICE_WECHAT_URL
          stringByReplacingOccurrencesOfString:@"REPLACE_DYNAMIC_KEY"
                                    withString:encodedToken] copy]
                   headers:nil
                  infoDict:infoDict];
  request.logInfoDict = [self logInfoDictForInfoDict:infoDict];

  __block NSPushRequestResendHandler resendHandler;
  resendHandler = ^(NSPushRequest* request, NSURLResponse* response,
                    NSData* data, NSError* error,
                    void (^completion)(NSPushRequest* request, BOOL shouldFail)) {
    if (error || !data) {
      completion(nil, NO);
      return;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data
                                              options:0
                                                error:nil];
    if (![json isKindOfClass:NSDictionary.class]) {
      request.failureReason = @"WeChat returned an invalid/non-JSON response";
      completion(nil, YES);
      return;
    }

    id errcodeValue = json[@"errcode"];
    // WeChat always returns errcode as a number on the message/send API.
    // Guard against missing/NSNull/non-numeric values: [nil integerValue]
    // would read as 0 and silently log a malformed response as success, while
    // [NSNull integerValue] would crash. Fail loudly instead.
    if (![errcodeValue respondsToSelector:@selector(integerValue)]) {
      request.failureReason =
          @"WeChat returned a response without a valid errcode";
      completion(nil, YES);
      return;
    }
    NSInteger errcode = [errcodeValue integerValue];
    NSString* errmsg = XStrDefault(json[@"errmsg"], @"");
    // 40014 = invalid access_token, 42001 = access_token expired.
    BOOL tokenExpired = (errcode == 40014 || errcode == 42001);
    if (!tokenExpired) {
      // A non-zero WeChat errcode means the message was not accepted. Do not
      // fall through to the sender's generic "HTTP response = success" path;
      // mark it as a real failure instead.
      if (errcode != 0) {
        request.failureReason =
            XStr(@"WeChat send failed (errcode=%ld, errmsg=%@)",
                 (long)errcode, errmsg);
        completion(nil, YES);
        return;
      }
      completion(nil, NO);
      return;
    }

    // Refresh the token. Pass the rejected token so the single-flight method
    // only invalidates the cache if it still holds this same stale token; if a
    // concurrent refresh already stored a newer token, that token is reused.
    [self fetchAccessTokenWithCorpid:corpid
                          corpsecret:corpsecret
                    invalidatingToken:token
                          completion:^(NSString* newToken, NSInteger expiresIn) {
      if (!newToken || newToken.length == 0) {
        request.failureReason =
            XStr(@"WeChat access_token invalid (errcode=%ld, errmsg=%@); "
                 @"refresh failed",
                 (long)errcode, errmsg);
        // Do not abort the send on a single failed gettoken: the failure is
        // usually transient (network hiccup) and the sender still has retry
        // budget. Resend the original request so the next attempt re-drives
        // the refresh, instead of permanently dropping the notification.
        // (completion(nil, NO) would be wrong here: the sender would replay
        // the original 40014 response through its success path.)
        completion(request, NO);
        return;
      }
      // fetchAccessTokenWithCorpid:already cached the fresh token before
      // invoking this completion, so no need to write the cache again here.
      NSPushRequest* newRequest =
          [self wechatPushRequestWithToken:newToken
                                  infoDict:request.infoDict
                                   cacheKey:cacheKey
                                    corpid:corpid
                                  corpsecret:corpsecret];
      completion(newRequest, NO);
    }];
  };
  request.resendHandler = resendHandler;
  return request;
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
static NSMutableDictionary* wechatPendingFetches = nil;
static dispatch_once_t wechatTokenCacheOnceToken;

static void wechatTokenCacheInit(void) {
  dispatch_once(&wechatTokenCacheOnceToken, ^{
    wechatTokenCache = [NSMutableDictionary new];
    wechatPendingFetches = [NSMutableDictionary new];
    wechatTokenCacheLock = [NSObject new];
  });
}

static NSString* cachedWechatTokenForKey(NSString* cacheKey, BOOL* hit) {
  wechatTokenCacheInit();
  @synchronized(wechatTokenCacheLock) {
    NSDictionary* entry = wechatTokenCache[cacheKey];
    NSDate* expireDate = entry[@"expire"];
    if (entry && [expireDate isKindOfClass:NSDate.class] &&
        [expireDate timeIntervalSinceNow] > 0) {
      *hit = YES;
      return entry[@"token"];
    }
  }
  *hit = NO;
  return nil;
}

static void cacheWechatTokenForKey(NSString* cacheKey,
                                   NSString* token,
                                   NSInteger expiresIn) {
  wechatTokenCacheInit();
  if (!token || token.length == 0) {
    return; // never cache an empty/failed token
  }
  // Cache with a small margin below WeChat's returned expires_in. If the
  // server returns an unusually small or invalid lifetime, do not extend it to
  // the default two hours; only use the default when expires_in is missing.
  NSTimeInterval cacheLifetime = 7200 - 60;
  if (expiresIn > 60) {
    cacheLifetime = expiresIn - 60;
  } else if (expiresIn > 0) {
    cacheLifetime = expiresIn;
  }
  NSDate* expire = [NSDate dateWithTimeIntervalSinceNow:cacheLifetime];
  @synchronized(wechatTokenCacheLock) {
    wechatTokenCache[cacheKey] = @{
      @"token" : token,
      @"expire" : expire,
      // Stored verbatim so cache hits can report the same expires_in that a
      // network fetch would.
      @"expiresIn" : @(expiresIn)
    };
  }
}

@end
