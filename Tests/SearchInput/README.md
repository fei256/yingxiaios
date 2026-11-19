# Input and control regression checks

This small iOS test app compiles the production search input, stable search surface, native picture gestures, player control targets, and dock control targets without the media dependencies.

Hosted UIKit tests check that the first input and IME updates keep the same text field and first responder, explicit focus requests still work, and the caret is vertically centered. UI tests tap the centers and corners of player and navigation buttons above the actual native gesture layer and check which action actually fires.

The workflow runs these checks on an iPad simulator before preparing media dependencies. They verify the shared components in a controlled host; they do not run the full player or replace physical iPad validation.
