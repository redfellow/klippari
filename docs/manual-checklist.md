# Manual checklist

Checks that need a person at the Mac, because they involve other apps,
system permissions or what is on screen. Walk the list after a change
to the app layer, using a build installed with `Scripts/build-app.sh`.
Expected behaviour is defined in `specification.md`.

## Capturing

- [ ] Copying text, an image and a file each adds a row, with no
      prompt from macOS about clipboard access.
- [ ] A password copied from the password manager does not appear.
- [ ] A password copied in Keychain Access or Passwords appears as
      dots only, with none of its characters, and a lock badge, is not in the storage folder, and is gone
      after 10 minutes.
- [ ] A copied API key (`sk-ant-…`, `ghp_…`) appears masked as prefix,
      dots and its last four characters; two keys can be told apart.
- [ ] A long line and a long file name lose their middle, not their
      end.
- [ ] Copying the same thing twice leaves one row, moved to the top.
- [ ] Capture keeps working after the Mac has been idle for a while.

## Panel

- [ ] Shift+Cmd+V opens the panel over the current app, which stays
      frontmost.
- [ ] The filter field has focus on every open, not just the first.
- [ ] Arrows, Ctrl+N / Ctrl+P and repeated Shift+Cmd+V move the
      selection.
- [ ] Typing filters; Esc clears the filter, then closes.
- [ ] Typing 'image' or 'png' lists images; 'text' and 'file' match
      only items that contain those words.
- [ ] Cmd+Backspace deletes the selected row.
- [ ] Shift+Cmd+Backspace clears every row at once and the notice says
      how many; Settings then shows them under Cleared history, and
      Restore brings them back in order, alongside anything copied
      since.
- [ ] Clearing, copying something and clearing again keeps both lots:
      Restore brings back everything from both clears.
- [ ] With Keep last lowered so the cleared history does not fit,
      Restore brings back only the newest items that fit, nothing in
      the history is pushed out, and Settings says how many did not
      fit. With the history full, Restore says that nothing was
      restored. Raising Keep last and pressing Restore again brings
      back the rest.
- [ ] Delete under Cleared history removes it, and the row goes away.
- [ ] After two clears an hour or more apart, Settings says 'last
      cleared' with the time of the second. A day after the first
      clear, its items are gone and the second clear's are still
      there; a day after the second, the row goes away.
- [ ] An item that could not be saved is cleared with the rest: with
      `~/Library/Application Support/Klippari/items` made read-only
      (`chmod 500`), copy something, then make it writable again
      (`chmod 700`) and press Shift+Cmd+Backspace. The notice counts
      the item, and Restore brings it back.
- [ ] A clear whose day runs out while the Mac sleeps is gone from
      Settings right after waking.
- [ ] Starting a build of this version over a cleared history left by
      an earlier build keeps it: Settings shows it with the date it
      had, and Restore brings it back.
- [ ] The panel looks right in light and dark mode, over light and
      dark windows, including its corners and blur.
- [ ] An image row shows a thumbnail.
- [ ] With Images on in Settings, an image in the first row shows
      large beside the panel on open, and arrowing through the list
      shows each selected image at once, with no delay or blank frame.
- [ ] The preview never covers the panel: it is to the right, or to
      the left when the panel is near the right edge, and stays on
      screen. Hovering another image's thumbnail shows that one at
      once; moving off goes back to the selection.
- [ ] Dragging the panel moves the preview with it, and the panel
      still has keyboard focus while the preview shows.
- [ ] The panel can be dragged by its search row and footer, reopens
      where it was left, and still does after a relaunch.
- [ ] Reset Panel Position in the menu puts it back in the middle.
- [ ] With Position on in Settings and Accessibility granted, the
      panel opens just above the text field being typed in, without
      covering it, wherever the pointer is: in TextEdit, Safari and
      Notes. In a long document it
      opens by the caret's line. Without a text field it opens just
      above the pointer; near the top of the screen it opens below it; near a
      side or corner it stays fully on screen. Copying while it is
      open above the pointer grows it upward.
- [ ] With Position on and a busy or hung app in front, the panel
      still opens within about 0.2 seconds, by the pointer.
- [ ] With Position on and VoiceOver off, the panel opens by the
      pointer over an Electron app (Slack, Discord, Claude), and the
      app stays as quick as before.
- [ ] With Position on and VoiceOver running (Cmd+F5), the panel opens
      by the text field in an Electron app, and by the pointer when
      focus is on a button. After closing it VoiceOver still reads the
      app's text fields and buttons. Turn VoiceOver off afterwards.
- [ ] With more than nine items, scrolling the list with the trackpad
      and reopening shows the first row selected and in view.

## Pasting

- [ ] Without the Accessibility permission, Return copies the item and
      the panel shows the notice; the system prompt appears once and
      does not hide the notice. Clicking the notice opens System
      Settings at Privacy & Security › Accessibility.
- [ ] With the permission, Return pastes into a text editor, a browser
      field and a terminal.
- [ ] Shift+Return pastes styled text as plain; an image pastes as-is.
- [ ] Cmd+1 to Cmd+9 paste that row.
- [ ] With Mouse on in Settings, moving the pointer over a row selects
      it, a click pastes it and Shift+click pastes plain text. Arrowing
      with the pointer resting on the list, and opening the panel with
      the pointer over a row, leave the keyboard selection alone.
      Pointing at a half-visible row at the list's edge does not scroll
      the list. With it off, rows ignore the mouse.
- [ ] A copied file pastes into a Finder window.
- [ ] The pasted item is first on the next open.
- [ ] Paste lands reliably in slow and in full-screen apps.
- [ ] Holding Return or Cmd+digit does not repeat into the target app.

## Menu bar and settings

- [ ] The menu bar icon shows in light and dark menu bars and dims
      while capture is paused.
- [ ] Pause stops capture, and resume does not record what was copied
      while paused.
- [ ] Clear History asks first, then empties the panel and the storage
      folder, and Settings offers to restore or delete what was
      cleared.
- [ ] After upgrading from 1.0, the history is still there, the old
      `items` folder is gone, every file in `items.noindex` starts with
      `KLP1`, and `mdfind -onlyin` on the Klippari folder finds
      nothing.
- [ ] Keychain Access shows 'Klippari history key'; another app asking
      for it gets a macOS prompt.
- [ ] With 'Klippari history key' deleted in Keychain Access and
      Klippari relaunched, the files in `items.noindex` are all still
      there, the menu starts with 'History isn't being saved' and the
      reason, and the panel's footer says the same on every open.
      Copies made now are gone after quitting.
- [ ] In that state, Reset Saved History… asks first, with no default
      button: Escape cancels and Return does nothing. After Reset the
      old files are gone, the two menu lines and the footer warning
      disappear, what was copied since
      launch is still listed, and it is still there after a relaunch.
- [ ] Release builds (Developer ID; needs the signing identity): the
      first launch on a Mac with no 'Klippari history key' makes the
      key without a prompt.
- [ ] Updating from one Developer ID build to the next opens the
      history without a prompt.
- [ ] A Mac that ran a dev-signed build first prompts once on moving
      to the release; Always Allow opens the history.
- [ ] Deny on the keychain prompt at launch: the menu says history
      isn't being saved, and Try Again, then Always Allow, opens the
      saved history with this run's copies in it.
- [ ] Over a 1.0 history with a few hundred items, large images among
      them: the menu bar icon answers at once, the menu says
      'Encrypting the saved history…' until the history opens, and
      the shortcut works from then on.
- [ ] With a different 'Klippari history key' put in the keychain (an
      older keychain restored, say), Klippari relaunched says 'The key
      in the keychain doesn't open it', keeps the old files, and
      Reset Saved History… deletes them and goes on saving with that
      key.
- [ ] A plain 1.0 item put into `items.noindex` after the first launch
      shows as '1 saved item can't be read', is not listed, and
      Delete Unreadable Items… removes it.
- [ ] Lowering the history size trims the list at once.
- [ ] Shortcut field: Return arms it, Esc cancels, Cmd+V and Cmd+Q are
      refused, and a failed registration keeps the previous shortcut.
- [ ] A changed shortcut takes effect at once and survives a relaunch.
- [ ] Settings can be operated with the keyboard alone.

## Installation

- [ ] Rebuilding with the script keeps the Accessibility permission.
- [ ] The app is listed and enabled under Login Items after first
      launch, and the Settings toggle turns it off and on.
- [ ] After logout and login the app is running with its history.
- [ ] The app icon shows in Finder.
