# SMS subscription service, injected into imagent.
#
# SpringBoard forwards notifications and cannot read the SMS database, so the
# only process that knows which SIM a message arrived on is the one that received
# it. This builds that process's side: a small dylib that answers a lookup over
# CPDistributedMessagingCenter, the same IPC the test-push path already uses.
#
# Swift is used for the database work — the parsing is ordinary string handling —
# and Logos for the hook, because `%hook` has no Swift equivalent.

# One architecture, matching the parent project: each scheme installs on one kind
# of device only, so building both doubles the work for a binary half of which is
# discarded.
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	ARCHS = arm64
else
	ARCHS = arm64e
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PusherSMS
PusherSMS_FILES = SMSHooks.xm SMSStore.swift
PusherSMS_CFLAGS = -fobjc-arc
# `NS_BLOCK_ASSERTIONS` turns `NSAssert` into a no-op. SandyXpc uses it for the
# listener it could not create, and an assertion inside a daemon is `abort()` —
# the last resort of a process whose failure should have been a log line.
PusherSMS_CFLAGS += -DNS_BLOCK_ASSERTIONS=1
PusherSMS_FRAMEWORKS = Foundation
PusherSMS_PRIVATE_FRAMEWORKS = AppSupport
# sqlite3 lives in the shared cache, so linking it adds no file.
PusherSMS_LIBRARIES = sqlite3
# SandyXpc: XPC without RocketBootstrap. Present in $(THEOS)/lib, installed as a
# package dependency rather than bundled.
PusherSMS_LIBRARIES += SandyXpc
PusherSMS_CFLAGS += -I$(THEOS)/include

include $(THEOS_MAKE_PATH)/tweak.mk
