THEOS_DEVICE_IP=192.168.0.219
THEOS_DEVICE_PORT=22

FINALPACKAGE = 1

# The package scheme must be named. It picks the layout the device needs, and
# guessing was never safe: a build without a scheme targets the classic rootful
# paths, which no supported device uses, and it fails in a way that looks like a
# code error rather than a missing argument.
#
#   make package THEOS_PACKAGE_SCHEME=roothide    # roothide / Dopamine
#   make package THEOS_PACKAGE_SCHEME=rootless    # rootless (elsewhere)
#
# Both use the 16.5 SDK: the deployment target is iOS 15, since neither layout
# exists before it, and the tweak reaches older systems only through the rootful
# build this repository no longer produces.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	TARGET = iphone:clang:16.5:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	TARGET = iphone:clang:16.5:15.0
else
$(error THEOS_PACKAGE_SCHEME must be set: use THEOS_PACKAGE_SCHEME=roothide (or =rootless). A rootful build is not supported — the 14.x SDK crashes Swift 6.3, and no supported device uses that layout)
endif

# The scheme also decides the install prefix and the rpath the Preferences
# bundle needs; without one, AltList.framework fails to load at runtime
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
