#import <Foundation/Foundation.h>

// Shared end-result filter values (also used by the segmented control in
// NSPLogController).
#define END_RESULT_ITEMS @[ @"Any", @"Blocked", @"Pushed" ]

// Pure data-layer helpers for the log viewer. Formatting and filtering are
// kept out of NSPLogController so the UI controller only owns cells, filters
// and table state.
@interface NSPLogFormatter : NSObject

// Builds a display title for one raw log-section dict (app name, timestamp,
// optional service prefix and optional stored "name").
+ (NSString*)sectionTitleForLogSection:(NSDictionary*)logSection;

// Whether a list of log strings should be shown under the current network
// response / end-result filters.
+ (BOOL)shouldIncludeLogs:(NSArray*)logs
          networkResponse:(NSString*)networkResponse
                endResult:(NSString*)endResult;

@end