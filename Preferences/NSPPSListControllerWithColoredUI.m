#import "NSPPSListControllerWithColoredUI.h"
#import "NSPColoredUI.h"
#import "NSPLocalization.h"
#import <Preferences/PSSpecifier.h>
#import "NSPusherManager.h"
#import "../UIImage+ReplaceColor.h"

@implementation NSPPSListControllerWithColoredUI

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self tintUIToPusherColor];
}

// override so we can dynamically set ui color later for each service to match
// icon
- (void)tintUIToPusherColor {
  [self nsp_tintNavigationBarAndControls];
  [self.table reloadData];
}

- (void)scrollViewWillBeginDragging:(UIScrollView*)scrollView {
  [self.view endEditing:YES];
}

// tint color
- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  PSTableCell* cell = (PSTableCell*)[super tableView:tableView
                               cellForRowAtIndexPath:indexPath];
  if (cell.type == PSLinkCell && cell.iconImageView &&
      cell.iconImageView.image) {
    UIImage* newImage = [cell.iconImageView.image
        imageByReplacingColor:PUSHER_COLOR
                    withColor:NSPusherManager.sharedController.activeTintColor];
    cell.iconImageView.image = newImage;
  }
  if (cell.type == PSButtonCell) {
    cell.titleLabel.textColor =
        NSPusherManager.sharedController.activeTintColor;
  }
  cell.tintColor = NSPusherManager.sharedController.activeTintColor;
  return cell;
}

// Ensure plist-loaded specifiers are localized even if the Preferences
// framework does not automatically apply the bundle's Localizable.strings to
// static specifier plists.
- (NSMutableArray*)loadSpecifiersFromPlistName:(NSString*)plistName
                                        target:(PSListController*)target {
  NSMutableArray* specifiers =
      [super loadSpecifiersFromPlistName:plistName target:target];

  for (PSSpecifier* specifier in specifiers) {
    NSString* name = specifier.name;
    if (name.length) {
      specifier.name = NSPLocalizedString(name, nil);
    }

    NSString* footer = [specifier propertyForKey:@"footerText"];
    if ([footer isKindOfClass:NSString.class] && footer.length) {
      [specifier setProperty:NSPLocalizedString(footer, nil)
                      forKey:@"footerText"];
    }

    NSArray* validTitles = [specifier propertyForKey:@"validTitles"];
    NSArray* validValues = [specifier propertyForKey:@"validValues"];
    if ([validTitles isKindOfClass:NSArray.class] && validTitles.count) {
      NSMutableArray* localizedTitles = [NSMutableArray array];
      for (id title in validTitles) {
        if ([title isKindOfClass:NSString.class]) {
          [localizedTitles addObject:NSPLocalizedString(title, nil)];
        } else {
          [localizedTitles addObject:title];
        }
      }
      if ([validValues isKindOfClass:NSArray.class] &&
          validValues.count == localizedTitles.count) {
        [specifier setValues:validValues titles:localizedTitles];
      } else {
        [specifier setProperty:localizedTitles forKey:@"validTitles"];
      }
    }
  }

  if (self.title.length) {
    self.title = NSPLocalizedString(self.title, nil);
  }

  return specifiers;
}

@end
