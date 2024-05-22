
@interface UIImage (Private)
+ (instancetype)_applicationIconImageForBundleIdentifier:
                    (NSString *)bundleIdentifier
                                                  format:(int)format
                                                   scale:(CGFloat)scale;
@end