# Preferences bundle.
#
# Bundles cannot have Swift static libraries, so the Core sources are compiled
# into this bundle directly (the same files the tweak compiles). That keeps one
# copy of the pipeline and guarantees the UI and the tweak read prefs the same
# way.

# The same Swift optimisation setting the tweak uses: this bundle compiles the
# identical Core sources, and two builds of one codebase that optimise differently
# would be a difference nobody could explain later. `-num-threads` is what makes a
# whole-module build use more than one core.
SWIFT_OPTFLAG = -O -whole-module-optimization -num-threads $(shell sysctl -n hw.ncpu)

# One architecture, matching the parent project: each scheme installs on one kind
# of device only, so building both doubles the work for a binary half of which is
# discarded.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	ARCHS = arm64
else
	ARCHS = arm64e
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = Pusher

Pusher_FILES = $(shell find $(THEOS_PROJECT_DIR)/Sources/Core $(THEOS_PROJECT_DIR)/Sources/Shared -name '*.swift') \
               $(wildcard *.swift)
Pusher_SWIFT_BRIDGING_HEADER = PusherBundle-Bridging-Header.h
Pusher_INSTALL_PATH = /Library/PreferenceBundles
Pusher_EXTRA_FRAMEWORKS = AltList
Pusher_FRAMEWORKS = UIKit Foundation SystemConfiguration MobileCoreServices
Pusher_LIBRARIES = z
Pusher_PRIVATE_FRAMEWORKS = Preferences AppSupport
Pusher_CFLAGS = -fobjc-arc
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
	Pusher_LDFLAGS += -rpath @loader_path/.jbroot/Library/Frameworks -rpath @loader_path/.jbroot/usr/lib
endif

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp Resources/entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/Pusher.plist$(ECHO_END)
