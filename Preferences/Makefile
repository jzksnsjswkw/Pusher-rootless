include $(THEOS)/makefiles/common.mk

# Keep the built-in service list in sync when building the bundle standalone.
before-all::
	../scripts/generate_builtin_services.sh

BUNDLE_NAME = Pusher
# Pusher_FILES = ../Shared/NSPushPrefsStore.m ../Shared/NSPushLogStore.m NSPRootListController.m NSPDeviceListController.m NSPServiceListController.m NSPServiceController.m NSPSharedSpecifiers.m NSPSharedSpecifiers+ServiceBuilders.m NSPCustomAppController.m NSPCustomizeAppsController.m NSPAppSelectionController.m NSPSoundListController.m NSPSNSListController.m CCLocalMaximum.m CCColorCube.m NSPPSViewControllerWithColoredUI.m NSPPSListControllerWithColoredUI.m NSPAppListController.m NSPLogController.m NSPLogFormatter.m ../UIImage+ReplaceColor.m NSPusherManager.m NSPGlobalSettingsListController.m
Pusher_FILES = ../Shared/NSPushPrefsStore.m ../Shared/NSPushLogStore.m NSPRootListController.m NSPServiceListController.m NSPServiceController.m NSPSharedSpecifiers.m NSPSharedSpecifiers+ServiceBuilders.m NSPushServicePrefs.m Services/NSPSharedSpecifiers+Pushover.m Services/NSPSharedSpecifiers+Pushbullet.m Services/NSPSharedSpecifiers+IFTTT.m Services/NSPSharedSpecifiers+Wechat.m Services/NSPSharedSpecifiers+Bark.m Services/NSPSharedSpecifiers+PusherReceiver.m NSPCustomAppController.m NSPCustomizeAppsController.m NSPAppSelectionController.m NSPAppMultiSelectionController.m NSPDeviceSoundListController.m NSPDeviceListController.m NSPSoundListController.m NSPSNSListController.m CCLocalMaximum.m CCColorCube.m NSPPSViewControllerWithColoredUI.m NSPPSListControllerWithColoredUI.m NSPColoredUI.m NSPAppListController.m NSPLogController.m NSPLogFormatter.m ../UIImage+ReplaceColor.m NSPusherManager.m NSPGlobalSettingsListController.m
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
