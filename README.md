# T3Notch

Alcove-style dynamic notch for [T3 Code](https://github.com/pingdotgg/t3code). Shows live agent progress, the TodoWrite task list, and lets you answer approvals/questions from under the Mac notch.

It surfaces the provider's own logo, the model, the machine the work is running on, how long the current turn has been going, and pending questions one slide at a time.

When several agents are running it shows a pressable card per agent, grouped by
project, and the panel widens to fit them. Picking a card switches the detail
below it. Above the task list sits an **Activity** feed of the agent's last five
actions — the commands it ran and the files it changed, whatever is still in
flight tinted. Commands are unwrapped from the `/bin/zsh -lc "…"` the agent runs
them through, and changed-file paths are shown relative to the worktree.

## First launch

The first run opens a quick start window: what the notch does, the three things
worth knowing, and a connection test that runs for real. Each of its four steps
makes the request it describes — discovery on port 3773 (falling back to
`server-runtime.json`), the `.well-known` environment endpoint, a Keychain or
freshly minted token, and an authorised `/api/orchestration/shell` read that
reports how many projects and threads are visible. Failures print what came back
plus the `t3 auth session issue --token-only` command, and steps that never ran
are marked skipped rather than left spinning. Closing the window or pressing
**Start using it** stops it reappearing; **Settings → Quick start → Show** brings
it back, as does **Quick Start…** in the menu bar item. Only a real close clears
the flag (`windowShouldClose`), because `windowWillClose` also fires while the app
is quitting, and a restarted first launch would otherwise skip the walkthrough
forever.

While either window is open the app switches from `.accessory` to `.regular`
activation and back again on close. An accessory app owns no Dock tile, no ⌘Tab
entry and no menu bar, so a window opened from a status item cannot be found again
once something covers it. Being briefly regular fixes all three, and brings a
menu bar that has to exist for the window's own shortcuts to work: ⌘C on the
selectable diagnostics, ⌘W, ⌘Q. Both windows draw their own top inset for the
floating traffic lights, since padding applied outside them leaves the window's
flat black showing above the gradient.

The notch takes part rather than being described in the abstract. With nothing
running it would normally hide, so while the window is open it holds the collapsed
pill labelled **Quick start**; pointing at a step opens the panel showing that
step, with a shorter hint written for the narrower panel; and the connection test
is echoed there as it runs, ending on the environment and thread count. The step
text lives in `Walkthrough.steps`, so the window and the notch cannot drift apart.
A waiting agent still outranks all of it — the walkthrough sits below the
attention branch in `updatePresentation`, above an idle notch.

The window owns that session (`beginWalkthrough`/`endWalkthrough`) and the view
inside it may only update one that is already open. A hosted view outlives a window
that is closed rather than released, so a connection test finishing afterwards
would otherwise switch the notch back on with no window left to explain it.

## Opening threads

**Open in T3 Code** brings the desktop app forward when it is running, and only
falls back to a browser tab when it is not. T3 Code registers `t3code://` but
handles no thread routes — a second instance just reveals the existing window —
so the app lands on whatever thread it was already showing rather than the one
from the notch. Activation goes through LaunchServices
(`NSWorkspace.openApplication`), because `NSRunningApplication.activate()` is
ignored for a caller that is not itself active, which the non-activating notch
panel never is. Turn **Open in the T3 Code app** off to always use the browser,
which does deep-link to the exact thread.

A finished agent stays pinned as a Done card until it is reviewed, rather than
flashing past. Two things clear it: pressing **Open in T3 Code** in the notch, or
settling the thread in T3 Code (`settledAt`). T3 Code's own read state lives in
renderer `localStorage` (`threadLastVisitedAtById`) and is not exposed over
HTTP, so simply opening the thread in the T3 Code window cannot clear the notch.
Threads that had already finished when the notch launched are treated as seen, so
the first snapshot does not pin all of history.

## Milestones

Two moments get an animation. Finishing a plan step bounces its tick and sends a
ring out of it, driven by a per-step counter that only increases so it fires once
per completion instead of on every poll. Finishing the whole plan, or landing a
branch, drops a banner into the panel — the merge one with a short confetti
burst — and holds the panel open for a few seconds, since these land exactly when
nobody is hovering.

Merges are detected without asking T3 Code, because merge state is only served
over its WebSocket RPC (`subscribeVcsStatus`, `getVcsStatus`) and this app speaks
the HTTP orchestration API. Two sources are consulted, the same two T3 Code uses:

- **The forge**, via `gh pr list --head <branch> --state merged --limit 1`, at most
  once a minute per branch. This is the only source that can see a squash merge:
  squashing rewrites the commits, so a squash-merged branch is *never* an ancestor
  of its base branch and no amount of local git will say otherwise. It is also
  what T3 Code itself drives, which is why T3 Code auto-settles a thread the
  moment its change request reports `merged`. Only pull requests merged after
  launch count, so history stays quiet. A missing, unauthenticated, or non-forge
  `gh` backs off for 15 minutes instead of spawning a process per poll.
- **The local repository**, for branches that land as a real merge commit or a
  fast-forward: `git rev-list --count <base>..<branch>` against the trunk and
  `origin/HEAD`, read-only, with `GIT_OPTIONAL_LOCKS=0`. Here a merge is reported
  only for a branch that was seen carrying commits the base lacked and later
  stopped carrying them, because "contained by main" alone is also true of two
  non-merges: a trunk-tracking thread, and a fresh worktree branch that has not
  committed yet.

Branches stay watched after their thread stops appearing in the notch, for up to
12 hours. A pull request is usually merged well after the agent stopped, and T3
Code auto-settles the thread as soon as it sees the merge — so a watcher that only
looked at currently listed threads would go blind exactly when the merge landed.
Several branches landing at once queue up and each get their own banner.

## Settings

**Settings…** in the menu bar item (⌘,) opens a control panel: dark rounded cards
with a hand-rolled switch, because a stock macOS settings window looks nothing
like the thing it configures. Every switch is wired to behaviour that actually
reads it — there are no decorative preferences:

| Setting | What reads it |
| --- | --- |
| Open on questions | the attention branch in `updatePresentation` |
| Play a sound | `playAttentionSound` |
| Keep finished agents pinned | `awaitsReview`, which is what pins a Done card |
| Celebrate tasks and merges | `celebrate`, and it dismisses anything on screen |
| Confetti on merges | the `ConfettiOverlay` in the expanded panel |
| Watch branches for merges | the 15s merge timer |
| Ask GitHub about pull requests | `MergeWatcher`'s forge: `.gh` or `.disabled` |
| Activity rows | `deriveRecentActivity(limit:)` |
| Task rows | the task list's row cap and its "+N more" |
| Display | `NotchGeometry.preferredScreen(named:)` |
| Launch at login | `SMAppService.mainApp` |
| Open in the T3 Code app | `openInT3Code`, before its browser fallback |

Values live in one struct persisted to `UserDefaults`, and writes go through a
single setter that saves and then calls `AgentStore.applySettings()`, so a flipped
switch takes effect immediately instead of on the next poll. Toggling the forge
setting rebuilds `MergeWatcher`, which deliberately forgets what it had seen: the
new watcher only reports merges from that moment on.

Two settings tell the truth rather than pretending. Launch at login reports what
`SMAppService` actually did — this app is ad-hoc signed, so registration can fail,
and the row shows the error and offers to open Login Items instead of leaving a
switch that looks on and does nothing. The display picker falls back to the
built-in notched screen whenever the chosen display is unplugged.

The Milestones section has **Preview** buttons for both animations, which is the
only way to see them without finishing a plan or merging a branch.

## Clocks

Elapsed labels read an observable `clock` on the store that ticks once a second
while the panel is visible and some turn is still open. Reading `Date()` inside a
label looks equivalent but freezes: SwiftUI re-renders on observable change, not
on the passage of time, so the label only moved when something else did — which,
with the mouse held still, was nothing. Finished turns now clamp to their
`completedAt` rather than counting up forever.

## Requirements

- macOS 26+
- Xcode 26.6+ (stable)
- A running T3 Code desktop/server on `127.0.0.1:3773`

## Build & run

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
chmod +x Scripts/bundle.sh
./Scripts/bundle.sh
open dist/T3Notch.app
```

`xcode-select` on this machine may point at Command Line Tools — always pin `DEVELOPER_DIR` as above.

## Icon

`Resources/AppIcon.icns` is generated, not hand-drawn. `Scripts/MakeAppIcon.swift`
draws it with SwiftUI and compiles against the app's own `NotchShape`, so the icon
and the panel can't drift apart. Sizes below 64px drop the interior detail, and
16px drops the accent dot, because both turn to mush at that scale.

```bash
./Scripts/make-icon.sh   # rewrites Resources/AppIcon.icns
```

`bundle.sh` copies the committed `.icns` into the bundle. The menu bar item draws
the same silhouette at 20×11 as a template image (`AppDelegate.statusItemImage`).

## Auth

On first launch T3Notch tries:

1. Keychain token
2. `t3 auth session issue --token-only`
3. `npx -y t3@latest auth session issue --token-only`

If that fails, paste a bearer token into the onboarding panel. Tokens are stored in the Keychain (`gg.t3tools.t3notch`).

## Dev

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
swift build
```

Open `Package.swift` in Xcode for debugging/previews.

## Architecture

- **T3NotchCore** — models, HTTP client, polling transport, derivations
- **T3Notch** — AppKit notch panel + SwiftUI UI

Provider logos are the same vector paths T3 Code's web app uses
(`apps/web/src/components/Icons.tsx`), parsed at runtime by `SVGPath.swift`, so
they stay pixel-faithful without bundling image assets. Machine name, OS and
arch come from `/.well-known/t3/environment`.

Thread detail (activity, tasks, context, pending prompts) rides one long-lived
`AsyncStream` per focused thread. `threadDetail(_:)` hands out a *fresh* stream
and ends the previous one, so it must only be called when focus actually moves —
`setFocusedThread` deliberately does not call it, and `subscribeDetail` ignores
requests for the thread it already follows. Re-subscribing on every shell
snapshot silently blanks the whole lower half of the panel.

The activity feed folds each `tool.started`/`tool.completed` pair into a single
row. The two carry no shared id, and fast commands log both inside the same
millisecond with no `sequence` field, so `orderedActivities` breaks ties by
lifecycle order — without that, half of all finished commands read as still
running (and the same tie could leave a resolved approval looking pending).

v1 uses adaptive HTTP polling of `/api/orchestration/shell` and `/api/orchestration/threads/:id`. A WebSocket Effect-RPC transport can replace `PollingTransport` later behind the same `T3Transport` protocol.
