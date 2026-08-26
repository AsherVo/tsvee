import Foundation

/// Cross-sheet ID following: the entry the user is looking at, and whether
/// switching to another sheet should line that sheet up on the same one.
///
/// On by default. Sheets kept open together almost always share an ID
/// namespace — stats in one, dialogue in another — and having them agree on
/// which entry you're editing is most of the reason they're open at once.
/// The toggle is a preference rather than session state, so it persists.
final class FollowState {

    static let shared = FollowState()

    private static let defaultsKey = "FollowCurrentID"
    private let defaults: UserDefaults

    /// Injectable so tests don't write to the user's real defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The ID of the row last selected in whichever sheet had focus. Only real
    /// entries land here: `#` headers, the field-name row and ID-less rows
    /// aren't entries, so selecting one leaves the last ID standing rather than
    /// blanking out where everything else is looking.
    var currentID: String?

    var isEnabled: Bool {
        // Absent means never toggled, which means on.
        get { defaults.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }
}
