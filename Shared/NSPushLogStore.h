#import <Foundation/Foundation.h>

// Central CFPreferences access for the Pusher log domain
// (com.noahsaso.pusher~log). Both the tweak core (NSPushLog) and the
// Preferences log viewer (NSPLogController) read/write the same per-service
// "<service>Log" arrays, so raw plist I/O and the reload notification live
// here in one dependency-free place.
@interface NSPushLogStore : NSObject

// Full raw snapshot of the log domain (nil-safe).
+ (NSDictionary*)snapshot;

// One service's log sections array (nil-safe; service @"" is the global log).
+ (NSArray*)logSectionsForService:(NSString*)service;

// Replace one service's log sections array and optionally post the log-updated
// Darwin notification.
+ (void)setLogSections:(NSArray*)logSections
            forService:(NSString*)service
          shouldNotify:(BOOL)shouldNotify;

// Remove one service's log entries (or all "..Log" keys for the viewer's
// "Clear All Logs" action). These do not post a notification; callers rebuild
// their UI directly.
+ (void)removeLogsForService:(NSString*)service;
+ (void)removeAllLogs;

@end