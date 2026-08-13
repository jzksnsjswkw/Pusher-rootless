#import "NSPWechatService.h"
#import "../../helpers.h"
#import "../NSPushServiceConfig.h"
#import "../NSPBulletinContext.h"

@implementation NSPWechatService

+ (NSString *)serviceName {
  return PUSHER_SERVICE_WECHAT;
}

+ (PusherAuthorizationType)authTypeForConfig:(NSPushServiceConfig *)config {
  return PusherAuthorizationTypeReplaceDynamicKey;
}

+ (NSDictionary *)credentialsForConfig:(NSPushServiceConfig *)config {
  return @{};
}

+ (NSString *)URLStringForConfig:(NSPushServiceConfig *)config {
  return PUSHER_SERVICE_WECHAT_URL;
}

+ (NSDictionary *)infoDictForBulletinContext:(NSPBulletinContext *)context
                                      config:(NSPushServiceConfig *)config {
  NSString *touser = config.rawPrefs[@"touser"];
  return @{
    @"touser" : (touser && [touser length] != 0) ? touser : @"@all",
    @"msgtype" : @"text",
    @"agentid" : config.rawPrefs[@"agentID"] ?: @"",
    @"text" : @{
      @"content" : XStr(@"%@\n%@", context.title ?: @"",
                        context.message ?: @"")
    },
    @"safe" : @"0"
  };
}

+ (void)fetchDynamicKeyForConfig:(NSPushServiceConfig *)config
                      completion:(void (^)(NSString *key))completion {
  NSString *corpid = config.rawPrefs[@"corpid"];
  NSString *corpsecret = config.rawPrefs[@"corpsecret"];
  if (!corpid || !corpsecret) {
    if (completion) {
      completion(nil);
    }
    return; // fixes double-callback bug in the original
  }

  NSString *reqUrl = @"https://qyapi.weixin.qq.com/cgi-bin/gettoken";
  NSDictionary *params = @{
    @"corpid" : corpid,
    @"corpsecret" : corpsecret
  };
  NSMutableArray *queryItems = [NSMutableArray array];
  for (NSString *key in params) {
    [queryItems addObject:[NSString stringWithFormat:@"%@=%@", key,
                                                     params[key]]];
  }
  NSString *queryString = [queryItems componentsJoinedByString:@"&"];
  reqUrl = [reqUrl stringByAppendingFormat:@"?%@", queryString];
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:reqUrl]];
  [request setHTTPMethod:@"POST"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSURLSession *session = [NSURLSession sharedSession];
  NSURLSessionDataTask *dataTask =
      [session dataTaskWithRequest:request
                 completionHandler:^(NSData *data, NSURLResponse *response,
                                     NSError *error) {
                   if (error) {
                     if (completion) {
                       completion(nil);
                     }
                     return;
                   }

                   NSDictionary *jsonResponse =
                       [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:nil];
                   if (![jsonResponse[@"errcode"] isEqual:@(0)]) {
                     if (completion) {
                       completion(nil);
                     }
                     return;
                   }
                   if (completion) {
                     completion(jsonResponse[@"access_token"]);
                   }
                 }];
  [dataTask resume];
}

@end
