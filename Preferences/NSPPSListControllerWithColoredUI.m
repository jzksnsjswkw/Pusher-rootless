#import "NSPPSListControllerWithColoredUI.h"
#import "NSPColoredUI.h"

@implementation NSPPSListControllerWithColoredUI

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self tintUIToPusherColor];
}

// override so we can dynamically set ui color later for each service to match icon
- (void)tintUIToPusherColor {
	[self nsp_tintNavigationBarAndControls];
	[self.table reloadData];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
	[self.view endEditing:YES];
}

// tint color
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	PSTableCell *cell = (PSTableCell *) [super tableView:tableView cellForRowAtIndexPath:indexPath];
	if (cell.type == PSLinkCell && cell.iconImageView && cell.iconImageView.image) {
		UIImage *newImage = [cell.iconImageView.image imageByReplacingColor:PUSHER_COLOR withColor:NSPusherManager.sharedController.activeTintColor];
		cell.iconImageView.image = newImage;
	}
	if (cell.type == PSButtonCell) {
		cell.titleLabel.textColor = NSPusherManager.sharedController.activeTintColor;
	}
	cell.tintColor = NSPusherManager.sharedController.activeTintColor;
	return cell;
}

@end
