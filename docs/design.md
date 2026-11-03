# WiredPad design language

The Mac app's windows follow these rules, so each new screen fits the others.

## Structure

- Settings use a sidebar of panes, like System Settings and Xcode. The window title is the pane's name, and the window opens on the pane used last.
- The General pane starts with the **stage**: the Mac, the link the video takes (USB, Wi‑Fi, AWDL, wired LAN) in the middle, and the device, side by side, with the link standing by beneath. It is the app's one picture, and it appears only there: repeated on every pane it becomes noise.
- The other panes start with a small header, as System Settings' panes do: the pane's symbol in the accent color, its name, and one line about it. Below it come standard grouped sections.

## Content

- Show real things only: each display's desktop picture (never what is on the screen), the device's name and kind, measured numbers, the actual key fingerprint. No decorative illustrations.
- Devices are drawn as their figures: a laptop for the Mac, a tablet or phone for the device, in the device's orientation.

## Color and motion

- The system accent color marks what is active (the link in use, keys set up). Inactive things are gray. A green dot marks a live connection or a setting that is on.
- Nothing moves on its own. State changes may animate briefly.
- No gradients, glows, colored icon tiles, pills, or cards inside cards.

## Type and text

- Object names in headline weight; state in small secondary text; numbers with monospaced digits.
- Keep labels short. Explanations go in a section footer or a tooltip, not in the rows.
- Use the device's own words: "Touch ID" or "Face ID" as the device has, "iPad" or "iPhone".

## Size

- Desktop density: standard control sizes, no oversized phone-style elements. The window is 720 × 480 points.
