#import "NSPushRequest.h"

@implementation NSPushRequest

+ (instancetype)requestWithURLString:(NSString*)urlString
                             headers:(NSDictionary*)headers
                            infoDict:(NSDictionary*)infoDict
                              method:(NSString*)method {
  NSPushRequest* request = [self new];
  request.urlString = [urlString isKindOfClass:NSString.class]
                          ? (NSString*)urlString
                          : @"";
  request.headers = [headers isKindOfClass:NSDictionary.class] ? headers : @{};
  request.infoDict = [infoDict isKindOfClass:NSDictionary.class] ? infoDict : @{};
  request.method = ([method isKindOfClass:NSString.class] &&
                          ((NSString*)method).length > 0)
                         ? (NSString*)method
                         : @"POST";
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