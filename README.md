# HandTrackingDebug

A standalone iPad app that runs **PlayFeat's hand tracking** and shows every
value that decides where a hand is and what state it's in — live, on top of
the camera.

## Run it

1. Open `HandTrackingDebug.xcodeproj` in Xcode.
2. Pick your iPad as the run destination (the Simulator has no camera).
3. If signing complains, choose your team under *Signing & Capabilities*.
4. Run, and allow camera access.

## What's on screen

**Overlay (left)**

| Mark | Meaning |
|---|---|
| Cyan dots / white bones | Vision's 21 joints per hand that are **trusted** (confidence ≥ threshold) |
| Red rings / faint red bones | Joints Vision reported but **below** the confidence threshold — ignored by the classifier |
| Yellow ring | This frame's **raw palm centre** (wrist + knuckles, averaged) |
| Big circle | The **smoothed cursor** the game uses. Green = open, orange = pinching, grey = coasting, cyan = new |
| Yellow line raw → circle | **Smoothing lag**: how far the cursor is behind the raw reading |
| Dashed ellipse around the circle | **Match radius**: next frame's reading must land inside to keep this ID |
| Thumb–index line + "gap" | **Pinch gap** in palm lengths. Orange ≤ close ratio, green ≥ open ratio, grey = dead zone |
| Magenta skeleton | The **player's** body (nearest person). Grey = anyone else |
| Dashed rings on the player's wrists | **Wrist reach**: a hand's own wrist must be inside to count as the player's |
| Red ✕ + text | A raw hand that was **rejected**, and why |

**Panel (right), in pipeline order**

1. **Frame** — fps, processing time, buffer size, whether body pose ran this frame.
2. **Sent to the game** — exactly what `HandPoseManager.hands` would contain.
3. **Identity tracker** — per hand: NEW / SEEN / COASTING, match distance vs radius,
   raw vs smoothed position, pinch gap gauge, pinch/apart evidence dots
   (fills up to *frames to commit*), and time missing vs grace period.
4. **Raw Vision hands** — every observation: Vision confidence, chirality, trusted
   joints, classifier result (palm, wrist, palm length, pinch gap) or rejection
   reason, body-filter verdict with distances, and all 21 joints.
5. **Bodies** — where they came from this frame, which is the player, shoulder
   span, wrist reach, which wrists were seen.
6. **Event log** — hand appeared, started coasting, recovered, dropped, pinch
   committed, released. Orange = something that could make the game misbehave.
7. **Tuning** — every knob, starting at PlayFeat's values. Change one and watch
   what it does; *Reset to PlayFeat values* puts them back.

**Freeze frame** holds the current frame on screen so you can read the numbers.
The pipeline (and the event log) keeps running underneath.

## Practice mode (grab & serve)

Turn on **Practice: grab & serve** in the panel. A board with plain shapes
appears over the camera — no game artwork needed:

1. **Four ingredients along the top.** Pinch while any part of your hand is
   inside the dashed ring to grab one. Carry it and it follows your hand.
2. **Drop it on the plate** by bringing it inside the plate's dashed ring.
   Open your hand anywhere else (for 0.18 s) to put it back on the table.
3. **After 3 ingredients** the dish is complete and a **SERVE HERE** tray
   appears on the left or right. Pinch on the plate to pick it up (it
   shrinks, like in the game) and carry it until it touches the tray's ring.
   Let go early and the plate goes back home.

The rules and numbers are PlayFeat's (`PracticeRules` in
`Debug/PracticeBoard.swift`): grab slack 30 pt, release delay 0.18 s, carried
items ease 50% per 60 Hz frame, a lost hand keeps what it holds for 0.35 s.
The panel shows what each hand is holding, how long it has been open, and a
log of every grab, drop and serve. All the tracking overlays stay on top, so
you can see exactly which data caused a grab to work or fail.

## How it relates to PlayFeat

`Pipeline/` holds **copies** of PlayFeat's files (each header says which file
and which commit). Changes there are only to *expose* values, and every such
line is marked `DEBUG` — the tracking rules themselves are untouched.

`Debug/FrameProcessor.swift` runs the same steps, in the same order, as
`HandPoseManager.process(pixelBuffer:)`, but records what each step decided.

Because these are copies, **they drift** when PlayFeat's tracking changes.
When that happens, copy the changed file over again and re-apply the
`DEBUG` lines.
