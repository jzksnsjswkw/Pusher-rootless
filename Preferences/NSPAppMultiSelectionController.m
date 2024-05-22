#import "NSPAppMultiSelectionController.h"
#include <Foundation/Foundation.h>

#import "../global.h"
#import "../helpers.h"
#import <notify.h>

@implementation NSPAppMultiSelectionController
@synthesize callback;

- (void)prepareForPopulatingSections {
  self.alphabeticIndexingEnabled = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  if (callback) {
    callback(self->_selectedApplications);
  }
}

@end
