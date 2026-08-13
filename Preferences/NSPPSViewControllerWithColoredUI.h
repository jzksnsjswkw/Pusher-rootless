#import "../global.h"
#import <Preferences/PSViewController.h>

@interface NSPPSViewControllerWithColoredUI : PSViewController {
  UIColor* _priorTintColor;
}
- (void)tintUIToPusherColor;
@end