

FINALPACKAGE = 1
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	TARGET = iphone:clang:16.5:14.5
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	TARGET = iphone:clang:16.5:14.5
else
	TARGET = iphone:clang:14.5:13.7
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Pusher
Pusher_FILES = Tweak.xm NSPTestPush.xm UIImage+ReplaceColor.m iOSVersion.m 	$(wildcard Core/*.m) $(wildcard Core/Services/*.m)
Pusher_CFLAGS += -fobjc-arc
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	Pusher_LIBRARIES += roothide
endif
Pusher_FRAMEWORKS = UIKit Foundation
Pusher_PRIVATE_FRAMEWORKS = AppSupport BulletinBoard

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
	# install.exec "killall -9 Preferences"
SUBPROJECTS += Preferences
SUBPROJECTS += Flipswitch
include $(THEOS_MAKE_PATH)/aggregate.mk
