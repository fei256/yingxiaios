import Foundation
import CoreGraphics

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

var taps = LocalHomeTapState()
check(taps.tap(at: 1) == .showHome, "First tap must navigate immediately")
check(taps.tap(at: 1.2) == .chooseHome, "Quick second tap must open the selector")
check(taps.tap(at: 1.21, blocked: true) == .ignored, "Triple tap cannot reopen a presenting selector")
check(taps.tap(at: 2) == .showHome, "Blocked taps must not remain paired")
check(taps.tap(at: 3) == .showHome, "Slow taps must remain single taps")
taps.reset()
check(taps.tap(at: 3.1) == .showHome, "Changing tabs must clear the previous tap")
check(taps.tap(at: .nan) == .ignored, "Invalid clock values cannot trigger a double tap")
check(taps.tap(at: 4) == .showHome, "Invalid values must clear the pending pair")
check(taps.tap(at: 3.9) == .showHome, "A backwards clock cannot trigger a double tap")
taps.reset()
check(taps.tap(at: 0) == .showHome, "Zero is a valid monotonic time")
check(taps.tap(at: LocalHomeTapState.doubleTapInterval) == .chooseHome, "The double tap boundary is inclusive")

let source = LocalHomeSourceSelection(origin: "https://sources.yingxia.invalid/record/version-a/subscription", sourceKey: "original", python: false)
let updated = LocalHomeSourceSelection(origin: "https://sources.yingxia.invalid/record/version-b/subscription", sourceKey: "original", python: false)
let pythonSource = LocalHomeSourceSelection(origin: "https://example.com/python", sourceKey: "original", python: true)
check(source == updated, "Downloaded source versions must keep their stable owner identity")
let target = LocalHomeTarget.source(source)
check(target.resolve(sources: [updated], htmlIDs: [], loadingGroups: []) == .available(target), "A matching stable source must resolve")
check(target.resolve(sources: [], htmlIDs: [], loadingGroups: [false]) == .waiting, "Restoring sources must wait rather than look deleted")
check(target.resolve(sources: [pythonSource], htmlIDs: [], loadingGroups: [true]) == .unavailable, "Another category cannot satisfy or indefinitely delay a source")
check(LocalHomeTarget.builtin.resolve(sources: [], htmlIDs: [], loadingGroups: [false, true]) == .available(.builtin), "Built-in home is always available")
check(LocalHomeTarget.html("saved").resolve(sources: [], htmlIDs: ["saved"], loadingGroups: []) == .available(.html("saved")), "HTML selection must restore by ID")
check(LocalHomeTarget.html("deleted").resolve(sources: [], htmlIDs: ["saved"], loadingGroups: []) == .unavailable, "A deleted HTML home must not resolve")
check(!LocalHomeTarget.html("builtin").isValid, "Built-in home cannot be encoded as an HTML ID")

let suite = "yingxia.navigation-tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
defaults.set("lastPython", forKey: "local.home.defaultDestination")
try target.save(defaults: defaults)
check(LocalHomeTarget.load(defaults: defaults) == target, "Selection must survive an encoding round trip")
check(defaults.string(forKey: "local.home.defaultDestination") == "lastPython", "Saving selection must not overwrite startup preference")
try LocalHomeTarget.html("saved").save(defaults: defaults)
check(LocalHomeTarget.load(defaults: defaults) == .html("saved"), "A changed home must replace the previous choice")
defaults.set(Data("invalid".utf8), forKey: LocalHomeTarget.storageKey)
check(LocalHomeTarget.load(defaults: defaults) == nil, "Invalid stored selection must be recoverable")

for container in [CGFloat(260), 320, 375, 390, 428, 768, 1024, 1366] {
    let available = container - 2 * LocalDockLayout.horizontalPadding
    let metrics = LocalDockLayout.metrics(availableWidth: available)
    check(metrics.width <= available, "Dock must fit the window")
    check(abs(metrics.buttonWidth * CGFloat(LocalDockLayout.itemCount) + 2 * metrics.padding - metrics.width) < 0.001, "Buttons must exactly fill the painted plate")
    if container >= 320 { check(metrics.buttonWidth >= 44, "Supported phone windows must keep basic touch targets") }
    for music in [false, true] {
        let frames = LocalDockLayout.touchFrames(containerWidth: container, showsMusic: music)
        check(frames.count == (music ? 2 : 1), "Only one navigation capsule must intercept touches")
        let dock = frames.last!
        check(dock.minX >= 0 && dock.maxX <= container, "Touch region must stay in the window")
        check(abs(dock.midX - container / 2) < 0.001 && dock.width == metrics.width, "Touch region must match the centered plate")
        check(dock.maxY + LocalDockLayout.bottomPadding == LocalDockLayout.inset(showsMusic: music), "Clearance must cover the painted dock")
        if music { check(frames[0].maxY + LocalDockLayout.musicSpacing == dock.minY, "Music strip must not overlap navigation") }
    }
}
check(LocalDockLayout.metrics(availableWidth: .nan).width == 0, "Invalid layout input must not create invalid frames")
check(LocalDockLayout.metrics(availableWidth: -1).buttonWidth == 0, "Negative layout input must not create negative buttons")
check(LocalDockLayout.accessoryBottom(containerBottom: 800, safeAreaBottom: 34, dockTop: 700, fallbackInset: 78) == 112, "Accessories must follow the actual dock position")
let largeTextFrames = LocalDockLayout.touchFrames(containerWidth: 375, showsMusic: true, controlHeight: 90)
check(largeTextFrames.last!.height == 98, "Large navigation text must grow the painted and touch plate together")
check(largeTextFrames.last!.maxY + LocalDockLayout.bottomPadding == LocalDockLayout.inset(showsMusic: true, controlHeight: 90), "Large text clearance must grow with the dock")
print("Home navigation state, persistence and dock geometry checks passed.")
