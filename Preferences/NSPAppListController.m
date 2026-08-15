#import "NSPAppListController.h"
#include <Foundation/Foundation.h>

#import "../helpers.h"
#import "NSPSharedSpecifiers.h"

@implementation NSPAppListController
- (void)viewDidLoad {
  [super viewDidLoad];

  _service = [self.specifier propertyForKey:@"service"];
  _isCustomService = NSPushBoolResolved(
      [self.specifier propertyForKey:@"isCustomService"], NO);
}

- (void)loadPreferences {
  // Get preferences
  _service = [self.specifier propertyForKey:@"service"];
  _isCustomService = NSPushBoolResolved(
      [self.specifier propertyForKey:@"isCustomService"], NO);
  _selectedApplications = [NSMutableSet new];
  if (_service) {
    NSArray* appList = _isCustomService
                           ? [NSPSharedSpecifiers
                                 customServiceAppListForService:_service]
                           : [NSPSharedSpecifiers
                                 builtInServiceAppListForService:_service];
    [_selectedApplications addObjectsFromArray:appList];
  } else {
    // The global app list lives nested under Global[appList]. Turning a
    // switch off removes the entry (arrays hold only selected app IDs).
    [_selectedApplications
        addObjectsFromArray:[NSPSharedSpecifiers globalAppList]];
  }
}

- (void)setApplicationEnabled:(NSNumber*)enabledNum
                    specifier:(PSSpecifier*)specifier {
  NSString* appID = [specifier propertyForKey:@"applicationIdentifier"];
  if ([enabledNum boolValue] != _defaultApplicationSwitchValue) {
    [_selectedApplications addObject:appID];
  } else {
    [_selectedApplications removeObject:appID];
  }

  if (_service) {
    if (_isCustomService) {
      [NSPSharedSpecifiers
          setCustomServiceAppList:_selectedApplications.allObjects
                       forService:_service];
    } else {
      [NSPSharedSpecifiers
          setBuiltInServiceAppList:_selectedApplications.allObjects
                        forService:_service];
    }
  } else {
    [NSPSharedSpecifiers setGlobalAppList:_selectedApplications.allObjects];
  }
}
@end
