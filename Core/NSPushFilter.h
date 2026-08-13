#import <BulletinBoard/BBBulletin.h>
#import <BulletinBoard/BBSectionInfo.h>
#import <Foundation/Foundation.h>

@class NSPushServiceConfig;
@class NSPushConfigSnapshot;
@class BBServer;

@interface NSPushFilter : NSObject

+ (NSString*)globalReasonIfAnyWithServer:(BBServer*)server
                                bulletin:(BBBulletin*)bulletin
                                  config:(NSPushConfigSnapshot*)config;

+ (NSString*)appListReasonIfAnyWithConfig:(NSPushServiceConfig*)config
                                    appID:(NSString*)appID;

+ (NSString*)snsReasonIfAnyWithSNS:(NSArray*)sns
                       sectionInfo:(BBSectionInfo*)sectionInfo
                             isAnd:(BOOL)isAnd
                   requireANWithOR:(BOOL)requireANWithOR;

+ (NSString*)deviceReasonIfAnyWithWhenToPush:(int)whenToPush
                                 whatNetwork:(int)whatNetwork;

@end
