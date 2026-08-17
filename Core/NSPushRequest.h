#import <Foundation/Foundation.h>

@class NSPushRequest;

// Called after a send attempt gets a response/error. The handler may inspect
// the result and either:
//   - call completion(nil, NO) to let the sender continue its normal handling,
//   - call completion(newRequest, NO) to resend a (possibly refreshed)
//     request, or
//   - call completion(nil, YES) to stop and treat the attempt as failed.
// The callback may be asynchronous (e.g. refresh an expired access token).
typedef void (^NSPushRequestResendHandler)(NSPushRequest* request,
                                           NSURLResponse* response,
                                           NSData* data,
                                           NSError* error,
                                           void (^completion)(NSPushRequest* request,
                                                              BOOL shouldFail));

// Unified push request model: a single object carrying everything the request
// sender needs (URL, headers, body dict and HTTP method). It replaces the old
// url/header/body triplet that services fetched through three independent
// protocol methods.
@interface NSPushRequest : NSObject

@property(nonatomic, copy) NSString* urlString;
@property(nonatomic, copy) NSDictionary* headers;
@property(nonatomic, copy) NSDictionary* infoDict;
// Optional sanitized copy of infoDict for logging (e.g. Base64 image fields
// replaced with placeholders). Services should set this; the sender logs it
// as-is and does not rewrite the real request body.
@property(nonatomic, copy) NSDictionary* logInfoDict;
@property(nonatomic, copy) NSString* method;
// Request body encoding for methods that carry a body: @"json" (default) or
// @"form" (application/x-www-form-urlencoded). GET/HEAD ignore this and put
// infoDict in the query string instead.
@property(nonatomic, copy) NSString* bodyType;
// Optional service-controlled resend hook. See NSPushRequestResendHandler.
@property(nonatomic, copy) NSPushRequestResendHandler resendHandler;
// Number of times this request has already been resent through resendHandler.
// The sender increments this on each service-triggered resend and uses the
// existing per-bulletin retry budget to prevent infinite resend loops.
@property(nonatomic, assign) NSUInteger resendCount;
// Optional human-readable reason set by a service when it marks the request as
// failed through resendHandler. The sender logs this reason if present.
@property(nonatomic, copy) NSString* failureReason;

+ (instancetype)requestWithURLString:(NSString*)urlString
                             headers:(NSDictionary*)headers
                            infoDict:(NSDictionary*)infoDict
                              method:(NSString*)method;

// Convenience: method defaults to @"POST".
+ (instancetype)requestWithURLString:(NSString*)urlString
                             headers:(NSDictionary*)headers
                            infoDict:(NSDictionary*)infoDict;

@end