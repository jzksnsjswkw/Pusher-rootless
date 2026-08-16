#import <Foundation/Foundation.h>

// Legacy flat-prefs migration routines used by NSPushPrefs(+loadSnapshot).
// Each takes the current raw plist snapshot and returns a (copy of the) dict
// with the legacy keys folded into the nested BuiltInServices / CustomServices
// / Global layout. The routines persist the migrated result through
// NSPushPrefsStore before returning.

NSDictionary* NSPushMigrateLegacyBuiltInServices(NSDictionary* prefs);
NSDictionary* NSPushMigrateLegacyCustomServices(NSDictionary* prefs);
NSDictionary* NSPushMigrateLegacyGlobal(NSDictionary* prefs);
