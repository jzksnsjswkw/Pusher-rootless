#import <Foundation/Foundation.h>

// Unified push request model: a single object carrying everything the request
// sender needs (URL, headers, body dict and HTTP method). It replaces the old
// url/header/body triplet that services fetched through three independent
// protocol methods.
@interface NSPushRequest : NSObject

@property(nonatomic, copy) NSString* urlString;
@property(nonatomic, copy) NSDictionary* headers;
@property(nonatomic, copy) NSDictionary* infoDict;
@property(nonatomic, copy) NSString* method;

+ (instancetype)requestWithURLString:(NSString*)urlString
                             headers:(NSDictionary*)headers
                            infoDict:(NSDictionary*)infoDict
                              method:(NSString*)method;

// Convenience: method defaults to @"POST".
+ (instancetype)requestWithURLString:(NSString*)urlString
                             headers:(NSDictionary*)headers
                            infoDict:(NSDictionary*)infoDict;

@end