# Fram Kartet

Nansen's 1893–96 expedition map — the same map that sits behind the chat in
Fram — as a living layer behind your windows. Agents who said something
recently camp on the map around your basecamp, wearing their real profile
pictures. An empty map is a quiet Fram.

| Signal | Meaning |
|---|---|
| Distance from basecamp | How often you talk: `daglig` / `ukentlig` / `sjelden` rings, from `messages30d` |
| Angle | Stable per agent (spread by sorted username within its ring), so camps never jump |
| Glow + quote bubble | Spoke within the hour; the freshest three carry their last message |
| Fading | Silence: full → 62 % after 1 h → 30 % after 6 h → gone after 24 h |
| Empty map | Nobody said anything in a day — the surface hides itself entirely |

## Layers & input

The field is scenery on the wlr `Bottom` layer: above the wallpaper, below
every window, with a zero-size input region so all clicks pass through
(the fram.lemmings trick). Two IPC verbs lift it:

- **Command mode** (`open`/`toggle`) raises it to `Overlay`, dims the desktop,
  and gives it input: hover a camp for the full message, click to open the
  agent in Fram over `fram://`. Esc closes.
- **Preview** (`preview`) shows the plain scenery look above the windows with
  input still off — exists so a screenshot can show what an empty desktop
  looks like without moving anyone's windows.

```bash
omarchy-shell fram.kartet toggle|open|close|preview|status
```

`status` prints what is drawn and how old the data is — first thing to check
when nothing appears.

## Where the data comes from

Two files under `~/.local/state/fram/`, read-only, polled every 2 s. The
plugin never talks to Fram, never touches the network (avatars are plain
public asset URLs fetched by Qt's image loader), and holds no credentials.

- `agents.json` — the roster: who exists, name, avatar, state. Historically
  written every 20 s by Fram Desktop; that writer died in the 2026-08-31 box
  reinstall and its code exists in no checkout or git ref on this box, so the
  file is currently a good-but-frozen snapshot. Roster churn is slow; the map
  survives this.
- `voices.json` — **contract this plugin defines**, published for real by
  `bin/fram-kartet-sync` (below):

```json
{
  "schemaVersion": 1,
  "updatedAt": "2026-08-31T22:50:43+0200",
  "voices": [
    { "id": "fram:bentsen", "lastMessage": "…", "lastAt": 1788214243, "messages30d": 24 }
  ]
}
```

### The real publisher: `bin/fram-kartet-sync`

Node script, no dependencies. Reads the engine token from `$FRAM_TOKEN` or
from the `.fram.json` the runtime rewrites into the agent workdir every turn,
then aggregates two API surfaces into per-agent voices: conversations of kind
`channel`/null (task threads are skipped as noise) and the expedition feed
(`/log_entries` — most crew activity is log entries, not chat; without the
feed the map goes almost dark). Incremental via
`~/.local/state/fram/kartet-sync-state.json`: steady-state runs fetch one
page per surface and finish in about a second. AI crew only; system messages
dropped; always exits 0 so the timer never flaps.

Run on a 5-minute systemd user timer (`systemd/` in this repo):

```bash
cp systemd/fram-kartet-sync.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now fram-kartet-sync.timer
```

Token caveat: the engine JWT expires within a day, so if no agent turn
refreshes `.fram.json` for that long the sync goes quiet (journal says why,
`lastError` lands in the state file) and voices simply age out — which is the
plugin's natural fade behaviour anyway.

### The mock, for demos and empty-state testing

`bin/fram-kartet-mock` writes the same file from the real roster (real names,
real avatars, staged ages), so the plugin cannot tell the difference. With the
timer active, sync overwrites the mock within five minutes.

```bash
bin/fram-kartet-mock              # one frame covering every ring and fade band
bin/fram-kartet-mock --count 8
bin/fram-kartet-mock --empty      # the field should self-hide
bin/fram-kartet-mock --restore    # hand voices.json back to the publisher
```

## Settings

`~/.config/fram/kartet.json`, re-read within two seconds — no shell restart.

| Key | Default | What it does |
|---|---|---|
| `enabled` | `true` | draw anything at all |
| `maxAgents` | `14` | hard cap on camps drawn |
| `wash` | `0.52` | paper wash over the map, 0–0.95 |
| `bubbles` | `3` | how many fresh voices carry a quote bubble |
| `ttlHours` | `24` | silence after which a camp strikes |
| `avatarSize` | `66` | avatar diameter, px |
| `youLabel` | `"deg"` | the basecamp label |

## Install

```bash
# by hand (dev)
cp -r . ~/.config/omarchy/plugins/fram.kartet/
omarchy-shell shell rescanPlugins
omarchy plugin enable fram.kartet

# from git, once pushed
omarchy plugin add <repo-url> --enable
```

Develop against a second Quickshell instance rather than the live shell, so a
broken component fails alone: `quickshell -p <plugin-dir>/shell.qml`
(`shell.qml` is a dev harness; the plugin loader only reads `manifest.json`).

## Notes for whoever touches this next

- **No `qs.Commons` import.** Only the manifest contract and Quickshell, so
  it survives an `omarchy update`.
- **The files are polled, not just watched.** Atomic writes (tmp + rename)
  swap the inode out from under inotify — a watch survives exactly one
  update, and a file created after startup is never seen. The 2 s poll covers
  both; `watchChanges` stays on because when it fires, it's instant.
- **Camps spread by sorted username per ring, not by hash** — hashing similar
  ids clusters them (the lemmings lesson). The hash only jitters spacing.
- **Fresh voices are ring-0 neighbours by nature**, so bubbles alternate
  sides by freshness rank and stagger vertically; splitting on the screen
  half puts all three bubbles in the same spot.
- **`font.pixelSize` is an int.** A literal `12.5` fails the whole component
  at load with a one-line error three imports away.
- **IPC functions need a shell restart** — QML hot-reload picks up bindings
  and visuals, but newly added `IpcHandler` functions only register on load.
