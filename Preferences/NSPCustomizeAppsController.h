#import "NSPPSViewControllerWithColoredUI.h"
// #import <AppList/AppList.h>
#import <AltList/AltList.h>

@interface NSPCustomizeAppsController : NSPPSViewControllerWithColoredUI <UITableViewDelegate, UITableViewDataSource> {
  UITableView *_table;
  NSArray *_sections;
  NSMutableDictionary *_data;
  NSString *_service;
  NSMutableDictionary *_customApps;
  // ALApplicationList *_appList;
  NSString *_prefsKey;
  NSString *_lastTargetAppID;
  NSIndexPath *_lastTargetIndexPath;

  NSArray *_defaultDevices;
  NSArray *_defaultSounds;
  NSString *_defaultEventName;
  NSNumber *_defaultIncludeIcon;
  NSNumber *_defaultIncludeImage;
  NSNumber *_defaultImageMaxWidth;
  NSNumber *_defaultImageMaxHeight;
  NSNumber *_defaultImageShrinkFactor;
  NSNumber *_defaultCurateData;

  NSMutableDictionary *_loadedAppControllers;

  BOOL _isCustomService;

  NSString *_label;
}
- (void)addAppIDs:(NSArray *)appIDs;
- (void)setAppDefaults:(NSString *)appID;
- (void)saveAppState;
- (void)sortAppIDArray:(NSMutableArray *)array;
- (void)updateTitle;
@end
