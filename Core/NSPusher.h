#import <BulletinBoard/BBBulletin.h>
#import <Foundation/Foundation.h>

@class NSPushConfigSnapshot;
@class NSPushServiceConfig;
@class NSPBulletinContext;
@class BBServer;

@interface NSPusher : NSObject

+ (instancetype)sharedInstance;

@property(nonatomic, readonly) NSPushConfigSnapshot* config;
@property(nonatomic, strong) BBServer* server;

- (void)reloadConfig;
- (void)handleBulletin:(BBBulletin*)bulletin;
- (void)sendToService:(NSString*)service
             bulletin:(BBBulletin*)bulletin
                appID:(NSString*)appID
              appName:(NSString*)appName
                title:(NSString*)title
              message:(NSString*)message
               isTest:(BOOL)isTest;

@end
