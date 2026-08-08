#import "NSPColoredUI.h"
#import "NSPusherManager.h"

@implementation UIViewController (NSPColoredUI)

- (void)nsp_tintNavigationBarAndControls {
  UIColor* color = NSPusherManager.sharedController.activeTintColor;

  UINavigationController* navController = self.navigationController;
  if ([[UIDevice currentDevice] userInterfaceIdiom] !=
      UIUserInterfaceIdiomPad) {
    navController = navController.navigationController;
  }
  navController.navigationBar.tintColor = color;

  [UISwitch appearanceWhenContainedInInstancesOfClasses:@[ self.class ]]
      .tintColor = color;
  [UISwitch appearanceWhenContainedInInstancesOfClasses:@[ self.class ]]
      .onTintColor = color;
  [UISegmentedControl
      appearanceWhenContainedInInstancesOfClasses:@[ self.class ]]
      .tintColor = color;
  [UISlider appearanceWhenContainedInInstancesOfClasses:@[ self.class ]]
      .tintColor = color;
}

@end
