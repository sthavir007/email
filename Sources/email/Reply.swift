import Foundation

/// Who a reply goes to. `me` is every address of every connected account (lowercased).
/// - Replying to someone else: their Reply-To (if it isn't you), otherwise the sender.
/// - Replying to your own email (sent folder, archive, your message inside a thread): the people you wrote to.
/// - Reply all adds the other To/Cc people, never you, never twice.
func replyRecipients(from: Address, replyTo: [Address], to: [Address], cc: [Address],
                     me: Set<String>, all: Bool) -> (to: [Address], cc: [Address]) {
    func mine(_ a: Address) -> Bool { me.contains(a.email.lowercased()) }
    var seen = Set<String>()
    func fresh(_ list: [Address]) -> [Address] {
        list.filter { seen.insert($0.email.lowercased()).inserted }
    }

    let fromMe = mine(from)
    var primary: [Address]
    if fromMe {
        primary = to.filter { !mine($0) }
        if primary.isEmpty { primary = to.isEmpty ? [from] : to } // a note to yourself
    } else {
        let rt = replyTo.filter { !mine($0) }
        primary = rt.isEmpty ? [from] : rt
    }
    primary = fresh(primary)
    guard all else { return (primary, []) }

    if !fromMe { primary += fresh(to.filter { !mine($0) }) }
    let ccOut = fresh(cc.filter { !mine($0) })
    return (primary, ccOut)
}
