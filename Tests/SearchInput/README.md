# Input and control regression checks

This small iOS test app compiles the production search input, stable search surface, native picture gestures, player control targets, and dock control targets without the media dependencies.

Hosted UIKit tests check that the first input and IME updates keep the same text field and first responder, explicit focus requests still work, and the caret is vertically centered. UI tests tap the centers and corners of player and navigation buttons above the actual native gesture layer and check which action actually fires.

The workflow runs these checks in an independent macOS job on the installed iOS 18.5 iPad simulator. The IPA job retains Xcode 16.1 and iOS 16.2 compatibility checks; simulator startup does not block archive creation. Both jobs must be reviewed for delivery validation. They verify the shared components in a controlled host; they do not run the full player or replace physical iPad validation.
