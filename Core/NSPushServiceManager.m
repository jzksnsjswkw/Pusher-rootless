#import "NSPushServiceManager.h"
#import "../global.h"
#import "Services/NSPBarkService.h"
#import "Services/NSPCustomService.h"
#import "Services/NSPFeishuService.h"
#import "Services/NSPIFTTTService.h"
#import "Services/NSPPushbulletService.h"
#import "Services/NSPPusherReceiverService.h"
#import "Services/NSPPushoverService.h"
#import "Services/NSPWechatService.h"

@implementation NSPushServiceManager

+ (Class)serviceClassForName:(NSString*)name {
  static NSDictionary* registry;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    registry = @{
      PUSHER_SERVICE_PUSHOVER : NSPPushoverService.class,
      PUSHER_SERVICE_PUSHBULLET : NSPPushbulletService.class,
      PUSHER_SERVICE_IFTTT : NSPIFTTTService.class,
      PUSHER_SERVICE_PUSHER_RECEIVER : NSPPusherReceiverService.class,
      PUSHER_SERVICE_FEISHU : NSPFeishuService.class,
      PUSHER_SERVICE_BARK : NSPBarkService.class,
      PUSHER_SERVICE_WECHAT : NSPWechatService.class
    };
  });
  return registry[name] ?: NSPCustomService.class;
}

+ (NSArray*)builtinServiceNames {
  return BUILTIN_PUSHER_SERVICES;
}

@end
