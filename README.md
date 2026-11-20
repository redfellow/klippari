<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Klippari app icon">
</p>

<h1 align="center">Klippari</h1>

<p align="center">A small background app for macOS that remembers the last things you
copied and lets you paste any of them easily from the keyboard.</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/panel-dark.png">
    <img src="docs/images/panel-light.png" width="760" alt="The Klippari panel listing recently copied text, an image, a file and a link, with the first row selected">
  </picture>
</p>

## What it does

- Records anything you copy regardless of content type: text, styled text, images, files
- Keeps the last 50 items by default, across restarts
- Never records what a password manager marks as concealed, nor
  anything over 20 MB
- Keeps other secrets (copies from password apps, API keys and tokens)
  in memory only, masked, for 10 minutes
- Pastes an item as it was copied, or as plain text
- Follows the system light or dark appearance
- Lives in the menu bar and starts at login

`docs/specification.md` describes the behaviour in full.

## Install

Requires macOS 15 or later, on Apple silicon or Intel.

1. Download `Klippari-<version>.dmg` from the
   [latest release](https://github.com/arime/klippari/releases/latest).
2. Open it and drag Klippari onto the Applications folder.
3. Open Klippari from Applications. The icon appears in the menu bar.
   Always run it from there: the Accessibility permission and the login
   item are tied to that copy.
4. Allow Klippari in System Settings › Privacy & Security ›
   Accessibility so it can paste into other apps.

## Keys

| Key                        | What it does                              |
| -------------------------- | ----------------------------------------- |
| Shift+Cmd+V (configurable) | Open the panel, move down the list        |
| Up / Down, Ctrl+P / Ctrl+N | Move the selection                        |
| Return                     | Paste the selected item as it was copied  |
| Shift+Return               | Paste it as plain text                    |
| Cmd+1 to Cmd+9             | Paste that row straight away              |
| Typing                     | Filter by text, file name or source app; `image` or `png` lists images |
| Cmd+Backspace              | Remove the selected item from the history |
| Shift+Cmd+Backspace        | Clear the history (restorable in Settings) |
| Cmd+S                      | Keep a secret as an ordinary item, saved  |
| Esc                        | Clear the filter, then close              |

The panel shows up to nine rows and scrolls beyond that. Drag it by
its search row or footer to move it. It reopens where you left it,
unless Position is on in Settings.

## Menu bar and settings

The menu bar icon has:

- **Pause/Resume Capture**: stop and restart recording.
- **Try Again**: only shown while the history isn't being saved. Opens
  the saved history again, as a relaunch would, after the keychain
  refused (Deny clicked by mistake) or the key was missing.
- **Reset Saved History…**: only shown when the saved history cannot
  be read because its key is gone from the keychain, or the keychain
  holds another key. Deletes what cannot be read, after a
  confirmation, and starts saving again: with a new key, or with the
  one in the keychain.
- **Delete Unreadable Items…**: only shown, under a line counting
  them, when the history is saved but some items on disk cannot be
  read with its key. Deletes them, after a confirmation.
- **Clear History**: clear every item, after a confirmation. Settings
  can restore what was cleared.
- **Reset Panel Position**: put the panel back in the middle.
- **Settings…**: history size (5 to 500 items), the shortcut, start at
  login, and three panel options, all off by default: **Mouse** (point
  at a row to select it, click to paste), **Position** (open next to
  the text field being typed in, or else the pointer) and **Images**
  (enlarge the selected image beside the panel). After a clear,
  **Cleared history** offers Restore and Delete.
- **Quit Klippari**.

To change the shortcut, select the field in Settings, press Return and
type the new combination. Standard commands such as Cmd+V and Cmd+Q are
refused.

## Build and install

Requires Xcode 26 or later on macOS 15 or later. There are no
third-party dependencies.

```bash
Scripts/build-app.sh --identity 'Apple Development: Your Name (TEAMID)'
```

This builds a release, signs it, installs it to
`/Applications/Klippari.app` and launches it. Always run the app from
there: the Accessibility permission and the login item are tied to that
bundle.

The signing identity is required and is not stored in the repository.
Pass it with `--identity`, or set the `CODESIGN_IDENTITY` environment
variable instead. List the identities on your Mac with:

```bash
security find-identity -v -p codesigning
```

Use the same identity for every build; with a different one, macOS
treats the build as a new app and asks for the Accessibility permission
again. Pass `--no-install` to only build into `build/`.

Run the unit tests with:

```bash
swift test
```

`docs/manual-checklist.md` lists the checks that need a person at the
Mac.

## Release

Releases are signed with a Developer ID certificate and notarized, so
they open without Gatekeeper warnings. Store the notarization
credentials in the keychain once, with an app-specific password:

```bash
xcrun notarytool store-credentials klippari-notary --apple-id you@example.com --team-id TEAMID
```

Set the version in `Resources/Info.plist`, then build the release disk
image:

```bash
Scripts/release.sh --identity 'Developer ID Application: Your Name (TEAMID)' --notary-profile klippari-notary
```

This writes `build/Klippari-<version>.dmg`, signed, notarized and
stapled. Tag the commit and publish it:

```bash
gh release create v1.0.0 build/Klippari-1.0.0.dmg --title 'Klippari 1.0.0'
```

## Permissions

- **Accessibility** (System Settings › Privacy & Security ›
  Accessibility). Needed to paste into other apps. Without it, Return
  still puts the item on the clipboard and the panel says what to
  grant. With Position on in Settings, it is also used to find the text
  field being typed in. Electron apps, such as Slack or Discord, show
  their fields only while an assistive tool such as VoiceOver is
  running. Klippari does not switch that on, so in them the panel
  opens at the pointer.

Reading the clipboard in the background needs no permission.

## What is stored, and where

History is kept in `~/Library/Application Support/Klippari/items.noindex`,
one folder per item, readable only by you and encrypted with a key kept
in your login keychain. Other apps that ask the keychain for that key
make macOS ask you first; deny them. That prompt guards reading the
key, not replacing it, so a small `key-check` file beside the history
tells Klippari whether the key in the keychain is still the history's:
a key replaced by another app is noticed and not used.

The keychain lets the build that made the key read it without asking.
A Mac that first ran a differently signed build of Klippari (a dev
build, say) asks once when it moves to the release; choose Always
Allow.

If the key cannot be had, the saved history is left as it is, and the
menu and the panel say that history isn't being saved. Try Again in
the menu, or a relaunch, opens it once the key can be had. Spotlight
and backups skip the folder. Settings are in the preferences of
`com.arime.Klippari`.

What the encryption does not hide: how large each item is, how many
types it has, whether it is an image, and when it was last used or
cleared. Files are bound to their item, but nothing stops a program
running as you from deleting an item or putting back an older copy
of one. A history from version 1.0 was plain, so copies of it in
earlier backups or snapshots stay readable.

Clearing the history moves it to a folder for that clear in
`items-archive.noindex` next to it, beside what was cleared before,
along with any item that could not be saved when it was copied.
Settings can restore or delete it. A restore brings back only as many
items as the history size has room for, newest first, and leaves the
rest to restore later. Each clear is deleted on its own 24 hours after
it was made, and the oldest go sooner if the cleared history passes
1 GB.

A copy taken for a secret is never written to disk. A copy counts as
one when it comes from a password app, even if you switch apps
straight after copying, or contains an API key or token in a
well-known format; it is shown masked and leaves the history after
10 minutes. Earlier copies of its text, in the history or the cleared
history, are deleted, so Restore cannot bring them back. If a copy is
wrongly taken for a secret, Cmd+S keeps it as an ordinary item, for
good. A token saved by an earlier version becomes a secret at launch.

This is a best guess, not a guarantee: a password copied from a
browser extension or in Terminal, or a token in a format Klippari does
not know, is saved like any other copy.

## Icon and screenshots

The app icon is drawn in code. To regenerate it after changing
`Scripts/make-icon.swift`:

```bash
swift Scripts/make-icon.swift build/AppIcon.iconset
```

```bash
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

The screenshots above are rendered by the app from sample items, so
they contain no real clipboard content:

```bash
.build/debug/Klippari --snapshot docs/images/panel-dark.png dark
```

## Layout

- `Sources/ClipboardCore`: content model, capture rules, storage,
  history, row presentation and panel state, all unit tested.
- `Sources/Klippari`: the app itself (shortcut, panel, pasting, menu
  bar, settings).
- `Scripts`: the build-and-install script, the release script and the
  icon generator.
- `docs/specification.md`: what the app does; the source of truth.
- `docs/manual-checklist.md`: checks that need a person at the Mac.
