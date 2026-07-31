<div align="center">

<img src="docs/icon.png" width="120" alt="StayAwake">

# StayAwake

**Keep your Mac awake with the lid closed, automatically, only while Claude Code is actually working.**

<img src="docs/panel.png" width="330" alt="The StayAwake panel: following Claude Code with 1 session and 5 agents working, live 5h and 7d usage bars with reset countdowns">

</div>

## Why

Close the lid and your Mac sleeps, whatever it was in the middle of. `caffeinate`
does not help: it holds off *idle* sleep, but closing the lid overrides power
assertions. The only thing that works is `pmset disablesleep`, which needs root
and is easy to leave switched on by accident, quietly draining your battery for
days.

StayAwake drives that flag from the menu bar, and can drive it for you.

## Auto mode

Turn on **Follow Claude Code** and the Mac stays awake exactly while Claude Code
is working, then hands sleep back when it finishes.

A process check cannot do this. The `claude` process stays alive the whole time
a session sits idle at the prompt, so "running" and "working" are different
things. StayAwake installs Claude Code hooks instead:

| Event | Action | Meaning |
|---|---|---|
| `UserPromptSubmit` | acquire | a turn started |
| `SubagentStart` | acquire | background agent started |
| `PostToolUse` | acquire | still working, keeps the claim young |
| `Stop` | release | turn finished |
| `StopFailure` | release | turn died: API error, usage limit |
| `SubagentStop` | release | background agent finished |
| `SessionEnd` | release | session gone |

Each working session writes a claim file, and sleep is held while any claim
exists. Claims are counted, sessions and background subagents separately, so
several sessions overlap correctly and a main-loop `Stop` cannot pull sleep out
from under an agent that is still running. Every claim records the process id
of the claude instance it belongs to, so a session that is killed hard or
crashes is pruned within seconds rather than after a timeout.

Sleep is handed back after **5 minutes of quiet**, not instantly. A turn ending
is not the same as you being done, and the grace covers the gap between turns so
a scheduled follow-up does not land on a sleeping machine.

An idle session deliberately holds nothing. A session waiting at the prompt is
finished, even though `claude` is still running.

**You outrank auto mode.** Turning Keep awake off by hand while Claude is
working pauses auto mode for the current work, and the panel says so; the next
fresh turn re-engages it. Without this the toggle would flip itself back on
within seconds of you switching it off.

## Install

Download the DMG from [Releases](../../releases), drag StayAwake to
Applications, and launch it.

First run opens a three-step setup:

1. **Allow sleep control.** One administrator prompt installs a sudoers rule
   granting exactly `pmset -a disablesleep 1` and `... 0` for your user, and
   nothing else. Without it, every change to the sleep flag would pop an
   authentication dialog, which makes auto mode unusable.
2. **Connect Claude Code.** Adds the six hooks above to
   `~/.claude/settings.json`. Your existing hooks are preserved; only entries
   mentioning `stayawake-claim` are touched, and the file is backed up first.
3. **Launch at login.** Without this the app stops running after a restart and
   auto mode silently stops working, because the hooks keep writing claims that
   nobody reads.

Every step is idempotent and re-runnable from the panel.

## Safety

**Battery guard.** Below 20% on battery, StayAwake hands sleep back even if
Claude is working, and sleeps the Mac if the lid is shut. It outranks both auto
mode and a manual hold, because it is the one rule that protects the machine
from the app. Toggleable.

**Quit restores sleep.** Leaving the flag set is the failure this app exists to
prevent, so quitting turns it back off.

**Recent activity.** The panel lists the last hold, release and sleep events
with times and reasons, so "did it actually work while I was away?" is a glance
rather than an archaeology session in `pmset -g log`.

**Usage limits.** A Claude usage limit is account-wide: when one session hits
it, nothing can work, so holding the Mac awake for it is pure battery drain.
When a turn dies on the limit, StayAwake sweeps every claim and the panel shows
"Claude usage limit hit · resets 3am" until fresh work proves the limit lifted.
Detection is deliberately conservative: only a failed turn triggers it, so a
conversation that merely mentions limits cannot.

**Resume after limit (optional).** The killer move: with "Resume after limit"
on, hitting a usage limit no longer ends your working day. The hook that
caught the failure releases its claim (so the Mac may sleep), then waits out
the reset inside the hook; StayAwake schedules a hardware RTC wake for the
reset time. When it fires, the hook un-fails the session and it continues
**in your own terminal, visibly, in the same conversation**. Sessions that
cannot continue in place (closed terminal, weekly limits beyond the wait cap)
are resumed headlessly with `claude --resume` instead — never both, and the
continuation's own hooks hold the Mac awake until the work finishes. Off by
default: resumed sessions run unattended with acceptEdits permissions
(configurable in Settings).

**Live usage bars.** The panel shows the 5-hour and 7-day windows as Claude
Code itself reports them, with live reset countdowns. These percentages ride
the statusline stream and exist nowhere else — no hook carries them — so setup
wraps your statusline command with a `tee` that copies each payload to a file
on its way through. Your statusline sees the same input and renders the same
output; StayAwake reads the copy. Only installed when you already have a
statusline configured, and the section hides itself when there is no feed.

**An honest status row.** Battery, power source and the sleep flag are read
in-process from IOKit, the same sources the menu bar battery flyout uses, and
plug/unplug pushes an immediate refresh. The row distinguishes on battery (with
time left), charging (with time to full), charged, and plugged-in-but-holding.
The "plug in or it will drain" warning appears only below twice the guard
threshold; a warning shown at 96% is noise that teaches you to ignore it. If
the app's own readings ever go stale, the row says so instead of showing old
numbers.

## Settings

Settings… in the panel opens a sidebar-style window: **General** (launch at
login, grace period, battery guard threshold, panel options), **Auto-resume**
(permissions for resumed sessions, the in-terminal wait cap, a custom continue
prompt), **Setup**, and **About**. Everything applies live — the app reads
these keys on every use, so there is no Save and no restart.

Every setting is also scriptable, same keys, same domain:

```sh
defaults write cz.sebastiankucera.stayawake graceSeconds 120         # default 300
defaults write cz.sebastiankucera.stayawake batteryThreshold 30      # default 20
defaults write cz.sebastiankucera.stayawake resumePermissionMode bypassPermissions
defaults write cz.sebastiankucera.stayawake resumeWaitCapHours 4     # default 6
defaults write cz.sebastiankucera.stayawake resumePrompt "..."       # continue prompt
defaults write cz.sebastiankucera.stayawake showUsageLimits -bool false
defaults write cz.sebastiankucera.stayawake debugHeartbeat -bool true
```

## Things worth knowing

**While sleep is disabled, the Apple menu's Sleep item will not work either.**
The flag is system wide, not lid specific.

**Releasing the flag is not enough to put a lid-shut Mac to sleep.** Clamshell
sleep fires on the lid-close *event*; clearing `disablesleep` afterwards never
replays it, and idle sleep does not cover it because browsers, `coreaudiod` and
`caffeinate` routinely hold idle-sleep assertions. So when auto mode releases
with the lid shut, StayAwake also calls `pmset sleepnow`. It skips that when an
external display is attached, since a shut lid plus a monitor means the machine
is in use.

This one was found the hard way: a lid closed with a session working, the
session died at 14:11, the flag correctly released at 14:16, and the Mac then
sat awake on battery until 16:32, draining 50% to 35%. The release worked.
Nothing turned it into actual sleep.

**The panel is an `NSPopover` from an `NSStatusItem`, not SwiftUI's
`MenuBarExtra`.** MenuBarExtra produced three distinct bug classes here: it did
not re-render on state changes (the panel went hours stale), it never made its
window key (dimmed switches, swallowed first clicks), and the re-render used to
paper over the first problem re-fired switch actions, flipping toggles the user
had just set. A popover becomes key on its own and hosts SwiftUI normally.
Related lesson, learned the same night: never probe disk or spawn a subprocess
inside a SwiftUI render pass. It corrupts the update graph (`AttributeGraph:
cycle detected`) and dropped state updates show up as UI that lies.

## Build from source

```sh
./tools/install.sh     # build, install to /Applications, relaunch
./build.sh             # build in place only
./tools/make-dmg.sh    # package, sign and notarise a release
```

`build.sh` signs with a Developer ID Application certificate when one is in the
keychain, applying the hardened runtime and a secure timestamp, and falls back
to ad-hoc otherwise. Releasing needs notarisation credentials stored once:

```sh
xcrun notarytool store-credentials notary \
  --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
```

The app and the DMG are notarised separately, on purpose: stapling only the DMG
leaves the copy dragged into /Applications without a ticket of its own, and a
first launch while offline can fail.

No Xcode project: a handful of Swift files compiled with `swiftc` into a bundle.

| File | Purpose |
|---|---|
| `StayAwake.swift` | app entry: `NSStatusItem`, the popover, app delegate |
| `Panel.swift` | the dropdown panel |
| `SettingsView.swift` | the settings window: sidebar, tabs, About |
| `SettingsWindow.swift` | settings window host |
| `SetupView.swift` | onboarding, embedded as the Setup tab |
| `Resume.swift` | auto-resume state shared by app and helper |
| `Setup.swift` | sudoers rule and hook installation |
| `Icon.swift` | menu bar art loading |
| `Power.swift` | `pmset` state, auto mode, battery guard, IOKit reads |
| `Claims.swift` | claim store shared by app and hook helper |
| `ClaimTool.swift` | `stayawake-claim`, invoked by hooks |
| `Activity.swift` | the recent-events log |
| `Login.swift` | login item registration |

### The artwork

Masters live in `Assets/source/`. After editing either state:

```sh
python3 tools/make-icons.py && ./build.sh
```

The generator does two things that are easy to miss. The sleeping master is an
opaque white body, invisible on a light menu bar, so it is converted to a
template mask and tinted by macOS. And art is placed by its **optical** centre,
not its bounding box: the creature's head is dense while its legs are thin
outlines, so a geometrically centred icon carries its weight high and visibly
sits above its neighbours.

### Testing

`STAYAWAKE_CLAUDE_DIR` points the hook writing at a scratch copy of
`settings.json` instead of your live one.

## License

MIT
