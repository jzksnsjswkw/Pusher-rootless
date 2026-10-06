#import <Foundation/Foundation.h>

@class BBBulletin;
@class NSPBulletinContext;
@class NSPushConfigSnapshot;

// The SpringBoard hook's entry point.
//
// handleBulletin: is called from the BBServer hook (Tweak.xm) with the raw
// BBBulletin. It is the only Core class that handles a BulletinBoard type, and
// it immediately converts it once into an NSPBulletinContext (see
// NSPBulletinAdapter). Everything from there on -- the filters, the request
// sender and the service payload builders -- works on that value object.
@interface NSPusher : NSObject

+ (instancetype)sharedInstance;

@property(nonatomic, readonly) NSPushConfigSnapshot* config;

- (void)reloadConfig;
- (void)handleBulletin:(BBBulletin*)bulletin;
- (void)sendToService:(NSString*)service context:(NSPBulletinContext*)context;

@end