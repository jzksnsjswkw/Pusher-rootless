#import "NSPCustomAppController.h"
#import "NSPLocalization.h"
#import "NSPSharedSpecifiers.h"

#import "../global.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPCustomAppController

- (id)initWithService:(NSString*)service
                appID:(NSString*)appID
             appTitle:(NSString*)appTitle
      isCustomService:(BOOL)isCustomService {
  if (self = [super init]) {
    // Copy: the caller (NSPCustomizeAppsController) passes strings owned by
    // its own state, which may be deallocated after we push this controller.
    _service = [service copy];
    _appID = [appID copy];
    _appTitle = [appTitle copy];
    _isCustomService = isCustomService;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.title = _appTitle;
}

- (NSArray*)specifiers {
  if (!_specifiers) {
    _specifiers = [[@[ [PSSpecifier groupSpecifierWithName:NSPLocalizedString(@"Customize", nil)] ]
        arrayByAddingObjectsFromArray:[NSPSharedSpecifiers
                                                      get:_service
                                                withAppID:_appID
                                          isCustomService:_isCustomService]]
        mutableCopy];
  }

  return _specifiers;
}

@end
