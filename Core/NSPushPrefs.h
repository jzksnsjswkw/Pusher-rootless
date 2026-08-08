#import <Foundation/Foundation.h>

@class NSPushConfigSnapshot;

@interface NSPushPrefs : NSObject

+ (NSPushConfigSnapshot *)loadSnapshot;

@end
