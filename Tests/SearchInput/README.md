# Input and control regression checks

This small iOS test app compiles the production search input, stable search surface, native picture gestures, player control targets, and dock control targets without the media dependencies.

The journal checks also compile the production background, cards, week strip and statistics picker. They check week/year boundaries, invalid airing dates, day/shortcut/period selections, and export screenshots from the iPad simulator using fixed fixture data. The fixture does not exercise source resolution or live TMDB requests.

Hosted UIKit tests check that the first input and IME updates keep the same text field and first responder, explicit focus requests still work, and the caret is vertically centered. UI tests tap the centers and corners of player and navigation buttons above the actual native gesture layer and check which action actually fires.

Control labels and bands publish their window frames. The production picture gesture view excludes those frames from native hit testing, so visible controls own their touches. Checks cover an ordinary UIKit button, SwiftUI reference buttons with and without the picture layer, 60 player/dock taps, and a picture tap outside the controls.

The workflow runs these checks in an independent macOS job on the installed iOS 18.5 iPad simulator. The IPA job uses Xcode 16.4 and retains iOS 16.1 deployment checks; simulator startup does not block archive creation. Both jobs must be reviewed for delivery validation. They verify the shared components in a controlled host; they do not run the full player or replace physical iPad validation.
