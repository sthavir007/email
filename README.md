# email

A minimal native mail client for macOS. Built with SwiftUI and Network.framework, with no third-party dependencies.

## What it does

- **Several accounts, one window.** Each account is a space with its own colours, plus an "everything" space that combines them. Swipe sideways with two fingers, or use ⌥⌘← and ⌥⌘→ or ⌘1 to ⌘9, to move between spaces.
- **Its own IMAP client and MIME parser.** Mail is sent over SMTP through the system's `curl`.
- **Google sign-in** with OAuth, or any IMAP account with an app password. Passwords and tokens are stored in the Keychain.
- **Undo for everything.** Archive, delete and send all wait six seconds and can be undone with ⌘Z.
- **Swipes and drags.** Swipe a row left to archive or delete, right to mark unread. Drag mail onto a folder, or out to Finder as an `.eml` file. Drag attachments in and out.
- **Readable threads.** Quoted replies are folded into an "earlier messages" section.
- **A Claude panel** (⌘J) that runs the Claude Code CLI with tools to search and read your mail and prepare drafts. It cannot send. You review each draft and send it yourself.
- **A moving black and white background** that reacts to clicks and pauses when the app is not in front.

## Build

Requires macOS 26 and the Swift toolchain.

```sh
./build.sh
```

This installs `~/Applications/email.app`. It signs with an Apple Development certificate if one is in the keychain, which keeps Keychain access working across rebuilds, and falls back to ad-hoc signing otherwise.

The Claude panel needs [Claude Code](https://claude.com/claude-code) installed and signed in. The rest of the app works without it.

### Google accounts

Google sign-in uses the OAuth client ID in `Sources/email/GoogleAuth.swift`. That client is in testing mode and only accepts accounts on its test list, so to use your own Google account, create an iOS-type OAuth client in the Google Cloud console for the bundle ID `com.sthavir.email` and put its ID there. Accounts with an app password need none of this.

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌘1 to ⌘9 | Go to a space |
| ⌥⌘← and ⌥⌘→ | Previous and next space |
| ⌘↩ | Send |
| ⌘Z | Undo the last move or send |
| Delete | Move the open email to the trash |
| Esc, twice | Close the open email |
| ⌘J | Open or close the Claude panel |

## Layout

| File | Purpose |
| --- | --- |
| `App.swift`, `Views.swift` | Window, sidebar, list and reader |
| `Store.swift`, `Accounts.swift` | Mail state, accounts and Keychain |
| `IMAP.swift`, `Socket.swift`, `MIME.swift` | IMAP client and message parsing |
| `SMTP.swift`, `Compose.swift`, `Reply.swift` | Writing and sending |
| `Thread.swift` | Folding quoted replies |
| `GoogleAuth.swift` | Google OAuth |
| `Chat.swift`, `Chats.swift`, `MCP.swift` | Claude panel and its mail tools |
| `Fluid.swift` | Animated background |
| `Drag.swift` | Drag and drop |

## Where data lives

- Accounts: `~/Library/Application Support/email/accounts.json`
- Secrets: Keychain, service `com.sthavir.email`
- Cached mail: `~/Library/Caches/com.sthavir.email`

## Not done yet

Microsoft sign-in, server-side search outside Gmail, push delivery (the app checks every two minutes) and HTML compose.
