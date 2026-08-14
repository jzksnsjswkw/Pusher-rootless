#import <AltList/AltList.h>

@interface NSPAppListController : ATLApplicationListMultiSelectionController {
  NSString* _prefix;
  NSString* _service;
  BOOL _isCustomService;
}
@end
