THEOS_DEVICE_IP=192.168.0.219
THEOS_DEVICE_PORT=22

FINALPACKAGE = 1

# iOS 15+ for the rootless/roothide schemes (they exist only on iOS 15+), and
# iOS 13.7 for a classic rootful build. The tweak itself supports iOS 10+ at
# runtime; the deployment target only bounds the SDK features it may use, so it
# is raised for the schemes that require it.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	TARGET = iphone:clang:16.5:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	TARGET = iphone:clang:16.5:15.0
else
	TARGET = iphone:clang:14.5:13.7
endif

# IMPORTANT: on roothide devices always build with
#   make package THEOS_PACKAGE_SCHEME=roothide
# Without an explicit scheme the Preferences bundle is linked without the
# @loader_path/.jbroot rpath and AltList.framework fails to load at runtime
# ("Library not loaded: @rpath/AltList.framework/AltList").

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Pusher

# Swift is the default language: Sources/Core is the whole pipeline,
# Sources/Shared is preference storage and logging, and only the two Logos files
# in Sources/Hooks are ObjC, because `%hook`/`%orig`/`%init` have no Swift
# equivalent.
Pusher_FILES = $(shell find Sources/Core Sources/Shared -name '*.swift') \
               Sources/Hooks/PusherHooks.xm \
               Sources/Hooks/TestPush.xm
Pusher_SWIFT_BRIDGING_HEADER = Sources/Hooks/Pusher-Bridging-Header.h
Pusher_CFLAGS = -fobjc-arc
Pusher_FRAMEWORKS = UIKit Foundation SystemConfiguration
# zlib: the icon encoder writes a palette PNG by hand (see IconPalette), and
# that needs a deflate pass; libz is in the shared cache, so this adds no file.
Pusher_LIBRARIES = z
Pusher_PRIVATE_FRAMEWORKS = AppSupport BulletinBoard

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"

SUBPROJECTS += Sources/Preferences
SUBPROJECTS += Sources/Flipswitch
include $(THEOS_MAKE_PATH)/aggregate.mk
