include $(THEOS)/makefiles/common.mk

# Keep the built-in service list in sync when building the bundle standalone.
before-all::
	../scripts/generate_builtin_services.sh

BUNDLE_NAME = Pusher
# Pusher_FILES = NSPRootListController.m NSPDeviceListController.m NSPServiceListController.m NSPServiceController.m NSPSharedSpecifiers.m NSPCustomAppController.m NSPCustomizeAppsController.m NSPAppSelectionController.m NSPSoundListController.m NSPSNSListController.m CCLocalMaximum.m CCColorCube.m NSPPSViewControllerWithColoredUI.m NSPPSListControllerWithColoredUI.m NSPAppListController.m NSPLogController.m ../UIImage+ReplaceColor.m NSPusherManager.m NSPGlobalSettingsListController.m
Pusher_FILES = NSPRootListController.m NSPServiceListController.m NSPServiceController.m NSPSharedSpecifiers.m NSPCustomAppController.m NSPCustomizeAppsController.m NSPAppSelectionController.m NSPAppMultiSelectionController.m NSPDeviceSoundListController.m NSPSNSListController.m CCLocalMaximum.m CCColorCube.m NSPPSViewControllerWithColoredUI.m NSPPSListControllerWithColoredUI.m NSPColoredUI.m NSPAppListController.m NSPLogController.m ../UIImage+ReplaceColor.m NSPusherManager.m NSPGlobalSettingsListController.m
Pusher_INSTALL_PATH = /Library/PreferenceBundles
Pusher_EXTRA_FRAMEWORKS = AltList
Pusher_FRAMEWORKS = UIKit Foundation MobileCoreServices
Pusher_PRIVATE_FRAMEWORKS = Preferences AppSupport
Pusher_CFLAGS = -fobjc-arc -Wno-objc-property-no-attribute
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	Pusher_LDFLAGS += -rpath @loader_path/.jbroot/Library/Frameworks -rpath @loader_path/.jbroot/usr/lib
endif

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/Pusher.plist$(ECHO_END)
