# Input and control regression checks

This small iOS test app compiles the production search input, stable search surface, native picture gestures, player control targets, and dock control targets without the media dependencies.

The journal checks also compile the production background, cards, week strip and statistics picker. They check week/year boundaries, invalid airing dates, day/shortcut/period selections, and export screenshots from the iPad simulator using fixed fixture data. The fixture does not exercise source resolution or live TMDB requests.

Hosted UIKit tests check that the first input and IME updates keep the same text field and first responder, explicit focus requests still work, and the caret is vertically centered. UI tests tap the centers and corners of player and navigation buttons above the actual native gesture layer and check which action actually fires.

Focus requests are acknowledged after the native responder state matches the command. Four additional checks use the production text field and coordinator to cover delayed window attachment/activation, a transient UIKit refusal, a newer dismissal during a failed attempt, and the four-attempt retry limit. Explicit focus assertions wait for the native responder state for at most two seconds.

Control labels and bands publish their global frames. The production picture gesture view excludes those frames in both UIKit and SwiftUI, since iOS 16 can otherwise hit the representable wrapper after its native view rejects a touch. Checks cover an ordinary UIKit button, SwiftUI reference buttons with and without the picture layer, 60 player/dock taps, 30 taps while changing portrait/landscape orientation, overlapping exclusions, and a picture tap outside the controls.

Each coordinate receives one tap, followed by a predicate wait of at most two seconds for the exact action identifier and cumulative count. Delayed accessibility observations and missing or duplicate actions retain a `control-action-receipt` attachment. A mismatch fails immediately at its original coordinate, so later assertions do not cascade from an already incorrect count.

The host also validates literal app symbol names and names from icon enum getters/category arrays against the running system's UIImage symbol catalogue. It compiles the production alias resolver, so controls using symbols introduced after iOS 16 retain an available icon. Dynamic icon names supplied by external sources are outside this static catalogue check.

The workflow runs these checks independently on the installed iOS 18.5 iPad simulator and on Apple's actual iOS 16.1 runtime. The IPA job uses Xcode 16.4 and retains iOS 16.1 deployment checks; simulator startup does not block archive creation. All jobs must be reviewed for delivery validation. They verify the shared components in a controlled host; they do not run the full player or replace physical iPad validation.
