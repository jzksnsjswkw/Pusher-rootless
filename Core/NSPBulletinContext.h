#import <BulletinBoard/BBBulletin.h>
#import <Foundation/Foundation.h>

@interface NSPBulletinContext : NSObject

@property(nonatomic, strong) BBBulletin* bulletin;
@property(nonatomic, copy) NSString* appID;
@property(nonatomic, copy) NSString* appName;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* message;
@property(nonatomic, assign) BOOL isTest;

+ (instancetype)contextWithBulletin:(BBBulletin*)bulletin
                              appID:(NSString*)appID
                            appName:(NSString*)appName
                              title:(NSString*)title
                            message:(NSString*)message
                             isTest:(BOOL)isTest;

- (NSString*)retryKeyForService:(NSString*)service;

@end
