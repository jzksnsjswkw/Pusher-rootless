#import "NSPRootListController.h"
#import "NSPusherManager.h"

@implementation NSPRootListController

- (void)viewDidLoad {
  [super viewDidLoad];
  if (!_priorTintColor) {
    UINavigationController* navController = self.navigationController;
    if ([[UIDevice currentDevice] userInterfaceIdiom] !=
        UIUserInterfaceIdiomPad) {
      navController = navController.navigationController;
    }
    _priorTintColor = navController.navigationBar.tintColor;
  }

  _showingHeader = NO;

  // Get the banner image
  UIImage* image = [UIImage imageNamed:@"banner" inBundle:PUSHER_BUNDLE];
  _headerImageView = [[UIImageView alloc] initWithImage:image];
  // Add header container
  _headerContainer = [UIView new];
  _headerContainer.backgroundColor = UIColor.clearColor;
  [_headerContainer addSubview:_headerImageView];

  // Update header image
  [self updateHeader];
}

- (void)updateHeader {
  CGFloat width = UIScreen.mainScreen.bounds.size.width;
  if ([[UIDevice currentDevice] userInterfaceIdiom] ==
      UIUserInterfaceIdiomPad) {
    width = self.rootController.view.frame.size.width;
  }

  // Resize frame to fit
  CGRect newFrame = _headerImageView.frame;
  // Banner image missing (or zero-sized): nothing to scale, avoid dividing by
  // zero below which would produce a NaN frame.
  if (newFrame.size.width == 0) {
    return;
  }
  CGFloat ratio = width / newFrame.size.width;
  newFrame.size.width = width;
  newFrame.size.height *= ratio;
  _headerImageView.frame = newFrame;
  _headerContainer.frame = newFrame;

  BOOL takesUpTooMuchScreen =
      newFrame.size.height >= UIScreen.mainScreen.bounds.size.height / 3.0;
  if (_showingHeader && takesUpTooMuchScreen) {
    [self.table setTableHeaderView:nil];
    self.title = @"Pusher";
    _showingHeader = NO;
  } else if (!_showingHeader && !takesUpTooMuchScreen) {
    [self.table setTableHeaderView:_headerContainer];
    self.title = nil;
    _showingHeader = YES;
  }
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  [self updateHeader];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [NSPusherManager.sharedController setActiveTintColor:nil];
  [self tintUIToPusherColor];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  UINavigationController* navController = self.navigationController;
  if ([[UIDevice currentDevice] userInterfaceIdiom] !=
      UIUserInterfaceIdiomPad) {
    navController = navController.navigationController;
  }
  navController.navigationBar.tintColor = _priorTintColor;
}

- (NSArray*)specifiers {
  if (!_specifiers) {
    _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
  }

  return _specifiers;
}

- (void)openTwitterNoahSaso {
  [NSPusherManager.sharedController openTwitter:@"NoahSaso"];
}

- (void)openGitHub {
  XUrl(@"https://github.com/jzksnsjswkw/Pusher-rootless");
}

@end
