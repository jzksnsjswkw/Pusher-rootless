// Bridging header for the Flipswitch bundle.
//
// This bundle is a control-center toggle: it reads and writes one preference and
// links none of the push pipeline. Its Swift sources are therefore limited to
// `Sources/Shared` (preference storage) plus the Flipswitch control itself, and
// this header imports only what those need.
//
// Flipswitch itself is an external framework, so its headers are vendored
// alongside the bundle (see `Include/`) instead of coming from the SDK.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Path resolution for a rootless / roothide install, and the Darwin
// notification API the switch uses to tell the tweak a preference changed.
#import <notify.h>
#import <roothide.h>

#import "Include/FSSwitchDataSource.h"
#import "Include/FSSwitchPanel.h"
#import "Include/FSSwitchState.h"
