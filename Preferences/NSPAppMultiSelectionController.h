#import <AltList/AltList.h>

typedef void (^PickerCallback)(id appIdOrIds);

@interface NSPAppMultiSelectionController : ATLApplicationListMultiSelectionController {
  PickerCallback callback;
}
@property(nonatomic, copy) PickerCallback callback;
@end
