#import "NSPushRequest.h"

@implementation NSPushRequest

+ (instancetype)requestWithURLString:(NSString*)urlString
                             headers:(NSDictionary*)headers
                            infoDict:(NSDictionary*)infoDict
                              method:(NSString*)method {
  NSPushRequest* request = [self new];
  request.urlString = urlString ?: @"";
  request.headers = headers ?: @{};
  request.infoDict = infoDict ?: @{};
  request.method = method ?: @"POST";
  return request;
}

+ (instancetype)requestWithURLString:(NSString*)urlString
                             headers:(NSDictionary*)headers
                            infoDict:(NSDictionary*)infoDict {
  return [self requestWithURLString:urlString
                            headers:headers
                           infoDict:infoDict
                             method:@"POST"];
}

@end