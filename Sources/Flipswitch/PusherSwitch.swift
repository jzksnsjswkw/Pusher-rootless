import Foundation

/// The Flipswitch control for Pusher.
///
/// Flipswitch is a control-center toggle framework: it loads a bundle and asks
/// its data source object for a state and to apply a new one. The bundle
/// advertises this class through its `Info.plist`, and the framework
/// instantiates it, so the class is visible to ObjC.
///
/// The switch is a thin adapter over the `Enabled` preference, which is the same
/// value the root settings page's first cell edits.
///
/// `FSSwitchState` is a plain C `enum`, so Swift imports it as a raw value and
/// the three cases are compared by their numeric values (which is also what the
/// framework does).
@objc(PusherSwitch)
public final class PusherSwitch: NSObject, FSSwitchDataSource {
    /// Off, on, and "the framework has not settled on a state yet".
    /// `FSSwitchState` is an `Int32`-backed C enum.
    private enum State {
        static let off: Int32 = 0
        static let on: Int32 = 1
    }

    /// The switch's display name, shown under the toggle.
    public func title(forSwitchIdentifier switchIdentifier: String) -> String {
        Pusher.name
    }

    /// Reads the current state straight from prefs.
    public func state(forSwitchIdentifier switchIdentifier: String) -> FSSwitchState {
        let enabled = PrefsStore.prefs().bool(PrefKey.enabled, default: true)
        return FSSwitchState(enabled ? State.on : State.off)
    }

    /// Stores the new state.
    ///
    /// The store posts the Darwin notification the tweak observes, so the change
    /// takes effect without a respring.
    public func apply(_ newState: FSSwitchState, forSwitchIdentifier switchIdentifier: String) {
        switch newState.rawValue {
        case State.on, State.off:
            PrefsStore.setValue(newState.rawValue == State.on, forKey: PrefKey.enabled)
        default:
            // Indeterminate: the framework is still resolving the state, so
            // there is nothing to store.
            break
        }
    }
}
