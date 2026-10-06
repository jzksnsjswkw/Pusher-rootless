import Foundation

/// Builds the private `BBAttachmentMetadata` for a synthetic bulletin.
///
/// The BulletinBoard class is linked (the tweak links BulletinBoard), but its
/// private initializers are not visible to Swift: one takes seven arguments,
/// which Swift cannot express through `perform(_:with:)`. The exact IMP
/// signature is therefore written out below.
///
/// The initializer changed in iOS 14. Both are attempted, newest first, so a
/// test push carries its image on every supported system.
enum BulletinAttachment {

    /// `- (_initWithUUID:type:URL:)` — pre-iOS 14.
    private typealias UUIDInitializer = @convention(c) (
        AnyObject, Selector, NSString, Int64, NSURL
    ) -> AnyObject?

    /// `- (_initWithType:URL:identifier:uniformType:thumbnailGeneratorUserInfo:thumbnailHidden:hiddenFromDefaultExpandedView:)`
    /// — iOS 14+.
    private typealias TypedInitializer = @convention(c) (
        AnyObject, Selector,
        Int64, NSURL, NSString, NSString,
        NSDictionary?, Bool, Bool
    ) -> AnyObject?

    /// An attachment for `url`, or `nil` when the class does not implement
    /// either initializer.
    static func make(url: URL, identifier: String, type: Int64 = 1) -> BBAttachmentMetadata? {
        guard let cls = Runtime.cls("BBAttachmentMetadata"),
              let metadata = (cls as? NSObject.Type)?.init()
        else { return nil }

        let modern = NSSelectorFromString(
            "_initWithType:URL:identifier:uniformType:thumbnailGeneratorUserInfo:"
                + "thumbnailHidden:hiddenFromDefaultExpandedView:"
        )
        if let method = class_getInstanceMethod(cls, modern) {
            let initialize = unsafeBitCast(
                method_getImplementation(method), to: TypedInitializer.self
            )
            // `thumbnailGeneratorUserInfo` is undocumented and unused here;
            // the values below match what the original tweak sent.
            let result = initialize(
                metadata, modern,
                type, url as NSURL, identifier as NSString, "public.png" as NSString,
                nil, true, false
            )
            if let attachment = result as? BBAttachmentMetadata { return attachment }
        }

        let legacy = NSSelectorFromString("_initWithUUID:type:URL:")
        if let method = class_getInstanceMethod(cls, legacy) {
            let initialize = unsafeBitCast(
                method_getImplementation(method), to: UUIDInitializer.self
            )
            return initialize(metadata, legacy, identifier as NSString, type, url as NSURL)
                as? BBAttachmentMetadata
        }
        return nil
    }
}
