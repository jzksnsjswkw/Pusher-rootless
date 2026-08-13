THEOS_DEVICE_IP=192.168.0.219
THEOS_DEVICE_PORT=22

FINALPACKAGE = 1
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	TARGET = iphone:clang:16.5:14.5
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	TARGET = iphone:clang:16.5:14.5
else
	TARGET = iphone:clang:14.5:13.7
endif

# IMPORTANT: On roothide devices always build with
#   make package THEOS_PACKAGE_SCHEME=roothide
# Without an explicit scheme the Preferences bundle is linked without the
# @loader_path/.jbroot rpath and AltList.framework fails to load at runtime
# ("Library not loaded: @rpath/AltList.framework/AltList").

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Pusher
Pusher_FILES = Tweak.xm NSPTestPush.xm UIImage+ReplaceColor.m iOSVersion.m 	$(wildcard Core/*.m) $(wildcard Core/Services/*.m)
Pusher_CFLAGS += -fobjc-arc
Pusher_FRAMEWORKS = UIKit Foundation
Pusher_PRIVATE_FRAMEWORKS = AppSupport BulletinBoard

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
	# install.exec "killall -9 Preferences"
SUBPROJECTS += Preferences
SUBPROJECTS += Flipswitch
include $(THEOS_MAKE_PATH)/aggregate.mk
