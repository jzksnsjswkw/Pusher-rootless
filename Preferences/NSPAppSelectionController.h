#import <AltList/AltList.h>

typedef void (^PickerCallback)(id appIdOrIds);

@interface NSPAppSelectionController : ATLApplicationListSelectionController {
  PickerCallback callback;
}
@property(nonatomic, retain) NSString *selectedAppID;
@property(nonatomic, copy) PickerCallback callback;
@end
