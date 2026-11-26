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
# One architecture per scheme, because each is only ever installed on one kind of
# device: roothide is arm64e, rootless is arm64. Theos builds both by default, so
# leaving it alone compiled every source file twice and threw half of it away at
# packaging time.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	TARGET = iphone:clang:16.5:15.0
	ARCHS = arm64
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	TARGET = iphone:clang:16.5:15.0
	ARCHS = arm64e
else
$(error THEOS_PACKAGE_SCHEME must be set: use THEOS_PACKAGE_SCHEME=roothide (or =rootless). A rootful build is not supported — the 14.x SDK crashes Swift 6.3, and no supported device uses that layout)
endif

# The scheme also decides the install prefix and the rpath the Preferences
# bundle needs; without one, AltList.framework fails to load at runtime
# ("Library not loaded: @rpath/AltList.framework/AltList").

# The package name carries `-rootless` on both schemes.
#
# Not a per-scheme suffix: a client keys a package on name and architecture
# together, so one name with two architectures is one row in Sileo and two debs on
# disk. That is what lets an upgrade cross schemes — the record that
# `dpkg --purge` removes is the same one, and the version comparison is between
# two builds of the same package rather than between two unrelated packages that
# happen to conflict.
#
# The bare `com.jzksnsjswkw.pusher` is kept as `Provides:` so anything that
# depended on a name this project used to publish still resolves.
#
# The display name is `Pusher-rootless` on both schemes, and the `sed` below is
# what enforces it: the template's own `Name:` is the same string, but one place
# deciding means a template edit cannot make the two schemes disagree.
#
# The source `control` is a template, never shipped: `deb.mk` reads it at parse
# time and the copy below is what ends up inside the deb. It carries no suffix for
# the same reason — the `sed` here is the only thing that decides, and a value in
# the file would only be a second place for it to go wrong.
PUSHER_PACKAGE_NAME := com.jzksnsjswkw.pusher-rootless
PUSHER_DISPLAY_NAME := Pusher-rootless

PUSHER_CONTROL := $(THEOS_PROJECT_DIR)/.theos/control.$(THEOS_PACKAGE_SCHEME)
$(shell mkdir -p $(THEOS_PROJECT_DIR)/.theos && \
        /usr/bin/sed -e 's|^Package: .*|Package: $(PUSHER_PACKAGE_NAME)|' \
                      -e 's|^Name: .*|Name: $(PUSHER_DISPLAY_NAME)|' \
            $(THEOS_PROJECT_DIR)/control > $(PUSHER_CONTROL))
_THEOS_DEB_PACKAGE_CONTROL_PATH := $(PUSHER_CONTROL)

include $(THEOS)/makefiles/common.mk

# `deb.mk` reads the project's `control` file at parse time, with `:=`, so the
# copy has to be handed over *after* that include — and before the packaging rules
# expand their recipes.
PUSHER_CONTROL := $(THEOS_PROJECT_DIR)/.theos/control.$(THEOS_PACKAGE_SCHEME)
$(shell mkdir -p $(THEOS_PROJECT_DIR)/.theos && \
        /usr/bin/sed -e 's|^Package: .*|Package: $(PUSHER_PACKAGE_NAME)|' \
                      -e 's|^Name: .*|Name: $(PUSHER_DISPLAY_NAME)|' \
            $(THEOS_PROJECT_DIR)/control > $(PUSHER_CONTROL))
_THEOS_DEB_PACKAGE_CONTROL_PATH := $(PUSHER_CONTROL)

# `package.mk` clears `THEOS_PACKAGE_NAME` and `deb.mk` recomputes it from the
# *source* control, so without this the deb is named after whatever the template
# says. The filename is what a release uploads and what the index links to; it has
# to carry the name the package does.
THEOS_PACKAGE_NAME := $(PUSHER_PACKAGE_NAME)

# Swift build settings for every target in this project.
#
# Theos defaults to `-O -whole-module-optimization -num-threads 1`: one `swiftc`
# invocation for the whole module, optimising with a single thread. That is the
# reason a build sits with one compiler process busy while eleven cores idle — the
# parallelism is inside that process, and it was switched off.
#
# `-num-threads` is raised to the core count. WMO then optimises functions on
# several threads inside the one invocation, which needs no change to the build
# graph and is where the wall-clock saving is.
#
# The Preferences bundle compiles the same Core sources, so it gets the same
# setting below.
PUSHER_SWIFT_OPTFLAG := -O -whole-module-optimization -num-threads $(shell sysctl -n hw.ncpu)
SWIFT_OPTFLAG = $(PUSHER_SWIFT_OPTFLAG)
export SWIFT_OPTFLAG

TWEAK_NAME = Pusher

# Swift is the default language: Sources/Core is the whole pipeline,
# Sources/Shared is preference storage and logging, and only the two Logos files
# in Sources/Hooks are ObjC, because `%hook`/`%orig`/`%init` have no Swift
# equivalent.
Pusher_FILES = $(shell find Sources/Core Sources/Shared -name '*.swift') \
               Sources/Hooks/PusherHooks.xm \
               Sources/Hooks/TestPush.xm \
               Sources/Hooks/ShortcutHooks.xm \
               Sources/Hooks/PusherBanner.m \
               $(shell find Sources/Core -name "*.m")
Pusher_SWIFT_BRIDGING_HEADER = Sources/Hooks/Pusher-Bridging-Header.h
Pusher_CFLAGS = -fobjc-arc
Pusher_FRAMEWORKS = UIKit Foundation SystemConfiguration
# zlib: the icon encoder writes a palette PNG by hand (see IconPalette), and
# that needs a deflate pass; libz is in the shared cache, so this adds no file.
# `z` for the palette PNG encoder, SandyXpc for the SMS lookup — the whole reason
# the library is a dependency is the sandbox: `bootstrap_look_up` from a tweak is
# refused, and going through libSandy's profile is what lets `imagent` publish a
# service this process may reach.
Pusher_LIBRARIES = z SandyXpc
Pusher_PRIVATE_FRAMEWORKS = AppSupport BulletinBoard

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard; killall -9 imagent || true"

SUBPROJECTS += Sources/Preferences
SUBPROJECTS += Sources/Flipswitch
SUBPROJECTS += Sources/SMSService
include $(THEOS_MAKE_PATH)/aggregate.mk
