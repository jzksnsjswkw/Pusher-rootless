TARGET = iphone:clang:16.5:15.0
FINALPACKAGE = 1


THEOS_PACKAGE_SCHEME=rootless
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Pusher
Pusher_FILES = Tweak.xm NSPTestPush.xm UIImage+ReplaceColor.m iOSVersion.m
Pusher_LIBRARIES = rocketbootstrap
Pusher_FRAMEWORKS = UIKit Foundation
Pusher_PRIVATE_FRAMEWORKS = AppSupport BulletinBoard

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
	# install.exec "killall -9 Preferences"
SUBPROJECTS += Preferences
SUBPROJECTS += Flipswitch
include $(THEOS_MAKE_PATH)/aggregate.mk
