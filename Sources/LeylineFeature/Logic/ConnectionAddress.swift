import Foundation

/// Resolves the caller-supplied `"connection"` string of `connect` and
/// `leyline.resolve_connection` to exactly one saved connection.
///
/// ## Why a label is now addressable, having deliberately not been
///
/// Both surfaces used to match on id ONLY, on the reasoning that labels are not
/// unique and picking the wrong one opens a session — or runs a command — on
/// the wrong machine. That reasoning was right about the risk and wrong about
/// the remedy. Ids are UUIDs, and the thing standing between the model and the
/// wrong host is the host's approval card, which shows the caller's string
/// verbatim. `Remote: 9F3A1C2E-4B7D-…` above `systemctl restart nginx` is
/// unreadable, so the human cannot catch the mistake the card exists to catch.
/// The card is synchronous and cannot look a label up, so the only lever is
/// making a readable identifier work in the first place.
///
/// The original concern is answered directly rather than dropped: an ambiguous
/// label is an ERROR naming the ambiguity, never a silent pick. Guessing was
/// the danger; matching a name that identifies exactly one machine is not.
///
/// ## Order, and why it is this order
///
/// 1. An exact id match wins outright — even if some *other* connection's label
///    is that same id string. An id is Leyline's own unforgeable name for a
///    connection; a label is user-typed text that can be made to mimic one.
/// 2. Otherwise, a unique case-insensitive label match.
/// 3. Two or more connections sharing that label → `.ambiguous`.
/// 4. Nothing → `.notFound`.
///
/// **Host and username are deliberately NOT matched.** A hostname is not a
/// user-chosen name for a machine, and two connections to one host with
/// different usernames are entirely normal — so a host match would be ambiguous
/// by construction in the common case rather than the rare one.
enum ConnectionAddress {

    /// What `resolve` concluded. The two failure cases are distinct because
    /// they need different advice: "no such connection" says list them, while
    /// "several match" says use the id.
    enum Match {
        case one(LeylineConnection)
        /// The shared label, and how many connections carry it.
        case ambiguous(label: String, count: Int)
        case notFound
    }

    static func resolve(
        _ identifier: String,
        in connections: [LeylineConnection]
    ) -> Match {
        if let byID = connections.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return .one(byID)
        }
        let byLabel = connections.filter {
            !$0.label.isEmpty && $0.label.caseInsensitiveCompare(identifier) == .orderedSame
        }
        switch byLabel.count {
        case 0: return .notFound
        case 1: return .one(byLabel[0])
        // The label echoed here is the STORED one, not the caller's string —
        // the same provenance as every other connection field these surfaces
        // already print, so "no tool output contains caller-supplied text"
        // still holds.
        default: return .ambiguous(label: byLabel[0].label, count: byLabel.count)
        }
    }

    /// The one wording both surfaces use, so a caller that hits it in the
    /// bridge and again in `connect` is not told two different things.
    static func ambiguityMessage(label: String, count: Int) -> String {
        "\(count) saved connections share the label \"\(label)\". Leyline will not guess which "
            + "machine you mean — call list_connections and pass the id of the one you want."
    }
}
