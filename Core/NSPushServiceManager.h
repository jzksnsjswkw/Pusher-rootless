#import <Foundation/Foundation.h>

@interface NSPushServiceManager : NSObject

+ (Class)serviceClassForName:(NSString *)name;
+ (NSArray *)builtinServiceNames;

@end
