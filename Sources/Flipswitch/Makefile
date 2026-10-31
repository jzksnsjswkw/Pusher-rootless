# Flipswitch bundle (control-center toggle).
#
# Compiles only the shared preference layer plus the switch itself: the toggle
# needs to read and write one preference, not the push pipeline.

# One architecture, matching the parent project: each scheme installs on one kind
# of device only, so building both doubles the work for a binary half of which is
# discarded.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	ARCHS = arm64
else
	ARCHS = arm64e
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = PusherFlipswitch
PusherFlipswitch_FILES = PusherSwitch.swift \
                         ../Core/PusherConstants.swift \
                         ../Shared/Prefs.swift \
                         ../Shared/PrefsStore.swift
PusherFlipswitch_SWIFT_BRIDGING_HEADER = PusherFlipswitch-Bridging-Header.h
PusherFlipswitch_FRAMEWORKS = UIKit Foundation
PusherFlipswitch_LIBRARIES = flipswitch
PusherFlipswitch_INSTALL_PATH = /Library/Switches

include $(THEOS_MAKE_PATH)/bundle.mk
