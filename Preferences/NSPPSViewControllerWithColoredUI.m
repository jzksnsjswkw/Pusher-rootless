#import "NSPPSViewControllerWithColoredUI.h"
#import "NSPColoredUI.h"

@implementation NSPPSViewControllerWithColoredUI

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self tintUIToPusherColor];
}

// override so we can dynamically set ui color later for each service to match
// icon
- (void)tintUIToPusherColor {
  [self nsp_tintNavigationBarAndControls];
}

@end
