#import "NSPBulletinContext.h"
#import "../global.h"
#import "../helpers.h"

@implementation NSPBulletinContext

+ (instancetype)contextWithBulletin:(BBBulletin*)bulletin
                              appID:(NSString*)appID
                            appName:(NSString*)appName
                              title:(NSString*)title
                            message:(NSString*)message
                             isTest:(BOOL)isTest {
  NSPBulletinContext* context = [self new];
  context.bulletin = bulletin;
  context.appID = appID;
  context.appName = appName;
  context.title = title;
  context.message = message;
  context.isTest = isTest;
  return context;
}

- (NSString*)retryKeyForService:(NSString*)service {
  return XStr(@"%@_%@_%@", self.bulletin.bulletinID ?: @"empty_bulletin_id",
              self.bulletin.sectionID, service);
}

@end
