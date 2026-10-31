import Foundation
import SQLite3

/// Reads one row out of the SMS database.
///
/// Only `imagent` may open this file: it is data-protected, and a root shell or a
/// dylib inside SpringBoard gets `EPERM` no matter what entitlements it carries.
/// That restriction is the whole reason this service exists — the SIM lookup
/// itself is answered by CoreTelephony in SpringBoard.
///
/// The column that matters is `destination_caller_id`: the number the message was
/// received on. `account` looks like the right field and is not — it holds the
/// device's default number and is the same for every message, which is why reading
/// it could not tell two SIMs apart.
public final class SMSStore: NSObject {
    /// The database Messages writes.
    static let path = "/var/mobile/Library/SMS/sms.db"

    /// The receiving number of the message with this identifier.
    ///
    /// `publisherBulletinID` on the notification is `message.guid`, so this is an
    /// exact lookup — no matching on sender, text or time.
    ///
    /// The slot comes from CoreTelephony in this process: it is already loaded for
    /// messaging, and resolving the number to a slot here means SpringBoard only
    /// has to look the slot up in its own settings rather than compare numbers.
    @objc(receivingNumberForGuid:)
    public static func receivingNumber(guid: String) -> [String: Any]? {
        guard !guid.isEmpty, let db = open() else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT destination_caller_id FROM message WHERE guid = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, guid, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0)
        else { return nil }

        let number = String(cString: cString)
        guard !number.isEmpty else { return nil }
        return ["found": true, "phoneNumber": number]
    }

    private static func open() -> OpaquePointer? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }
}

/// SQLite wants a destructor argument for the bound text; this is the constant
/// that means "copy it now", which is what a Swift string needs.
private let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)
