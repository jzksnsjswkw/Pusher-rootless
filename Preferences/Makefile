include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = Pusher
# Pusher_FILES = NSPRootListController.m NSPDeviceListController.m NSPServiceListController.m NSPServiceController.m NSPSharedSpecifiers.m NSPCustomAppController.m NSPCustomizeAppsController.m NSPAppSelectionController.m NSPSoundListController.m NSPSNSListController.m CCLocalMaximum.m CCColorCube.m NSPPSViewControllerWithColoredUI.m NSPPSListControllerWithColoredUI.m NSPAppListController.m NSPLogController.m ../UIImage+ReplaceColor.m NSPusherManager.m NSPGlobalSettingsListController.m
Pusher_FILES = NSPRootListController.m NSPDeviceListController.m NSPServiceListController.m NSPServiceController.m NSPSharedSpecifiers.m NSPCustomAppController.m NSPCustomizeAppsController.m NSPAppSelectionController.m NSPAppMultiSelectionController.m NSPSoundListController.m NSPSNSListController.m CCLocalMaximum.m CCColorCube.m NSPPSViewControllerWithColoredUI.m NSPPSListControllerWithColoredUI.m NSPAppListController.m NSPLogController.m ../UIImage+ReplaceColor.m NSPusherManager.m NSPGlobalSettingsListController.m
Pusher_INSTALL_PATH = /Library/PreferenceBundles
Pusher_EXTRA_FRAMEWORKS = AltList
Pusher_FRAMEWORKS = UIKit Foundation MobileCoreServices
Pusher_PRIVATE_FRAMEWORKS = Preferences AppSupport
Pusher_CFLAGS = -Wno-objc-property-no-attribute
Pusher_LIBRARIES = rocketbootstrap

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/Pusher.plist$(ECHO_END)
