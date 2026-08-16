#import "NSPGlobalSettingsListController.h"
#import "NSPLocalization.h"
#import "NSPSharedSpecifiers.h"

#import "../helpers.h"

@implementation NSPGlobalSettingsListController

- (NSArray*)specifiers {
  if (!_specifiers) {
    NSArray* appListSpecifiers =
        [self loadSpecifiersFromPlistName:@"GlobalAppList" target:self];
    NSArray* globalSettingsSpecifiers =
        [self loadSpecifiersFromPlistName:@"GlobalAndServices" target:self];

    // Route the Global App List cells through nested storage
    // (Global[appListIsBlacklist]). GlobalAndServices cells keep their native
    // flat keys (WhenToPush/WhatNetwork) since those are the global defaults.
    NSArray* specialCells = @[ @(PSGroupCell), @(PSButtonCell), @(PSLinkCell) ];
    for (PSSpecifier* specifier in appListSpecifiers) {
      if ([specialCells containsObject:@(specifier.cellType)]) {
        continue;
      }
      specifier->setter = @selector(setPreferenceValue:forGlobalSpecifier:);
      specifier->getter = @selector(readGlobalPreferenceValue:);
      specifier.target = NSPSharedSpecifiers.class;
      NSString* customServiceKey =
          [specifier propertyForKey:@"customServiceKey"];
      if (customServiceKey) {
        [specifier setProperty:customServiceKey forKey:@"key"];
      }
    }

    _specifiers = [[appListSpecifiers
        arrayByAddingObjectsFromArray:globalSettingsSpecifiers] mutableCopy];

    for (PSSpecifier* specifier in _specifiers) {
      if (specifier.cellType == PSLinkCell &&
          (XEq(specifier.name, @"Global App List") ||
           XEq(specifier.name, NSPLocalizedString(@"Global App List", nil)))) {
        specifier.name = XStr(
            NSPLocalizedString(@"%@ (%d total)", nil), specifier.name,
            (int)[NSPSharedSpecifiers globalAppList].count);
        // Non-retaining NSValue to avoid controller -> specifier -> controller
        // retain cycle.
        [specifier
            setProperty:[NSValue valueWithNonretainedObject:self]
                 forKey:@"psListRef"];
        break;
      }
    }
  }

  return _specifiers;
}

@end
