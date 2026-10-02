# Omarchy Media Bar

A Quickshell media-control module for Omarchy that provides a compact media bar with support for multiple MPRIS players and an interactive mpv queue.

The module uses:

- **Quickshell/QML** for the UI
- **Python** for media-player discovery, state management, and commands
- **playerctl/MPRIS** for generic media-player control
- **mpv IPC** for mpv-specific features such as playlist access and queue selection

## Features

- Display the currently active media title and artist
- Play/pause, previous, and next controls
- Automatically discover active MPRIS players
- Prioritize local/native players over browser tabs
- Switch between available media sources
- Show album artwork for local media
- Display playback position and duration
- Seek through the current track
- Display the mpv playlist as an expandable queue
- Display kew's MPRIS TrackList as an expandable queue
- Select an item from the mpv queue and start playback
- Select a kew queue item through MPRIS `GoTo`
- Automatically pause the previous source when switching players
- Optimistic play/pause UI updates for responsive controls

## Architecture

```text
                    ┌──────────────────────┐
                    │      Quickshell      │
                    │         QML          │
                    └──────────┬───────────┘
                               │
                         JSON commands
                               │
                               ▼
                    ┌──────────────────────┐
                    │   media-backend.py   │
                    └──────────┬───────────┘
                               │
                    ┌──────────┴──────────┐
                    │                     │
                    ▼                     ▼
              playerctl / MPRIS       mpv IPC
                    │                     │
          ┌─────────┼─────────┐           │
          ▼         ▼         ▼           ▼
         mpv       VLC     Spotify     playlist
       browser    etc.                 / queue
```

### MPRIS

`playerctl` is used to discover and control media players that expose the MPRIS interface.

The backend collects:

- playback status
- player name
- title
- artist
- album
- artwork URL
- playback position
- track duration

For kew, the backend also reads `org.mpris.MediaPlayer2.TrackList.Tracks` and
`GetTracksMetadata`, then selects queue entries with `GoTo`. Other MPRIS
players continue to use the existing player controls, and mpv continues to use
its IPC playlist.

Only players in `Playing` or `Paused` states are considered.

### Player priority

Players are assigned a priority based on whether they are local/native players and whether they are currently playing:

```text
Local + Playing     → highest priority
Local + Paused
Browser + Playing
Browser + Paused    → lowest priority
```

Browser-based MPRIS sources include Chromium, Chrome, Firefox, Brave, Edge, Opera, Vivaldi, LibreWolf, Waterfox, Epiphany, and Midori.

A selected local player remains pinned until it disappears. Browser sources can be selected manually, but an actively playing local player can reclaim priority.

### mpv IPC

MPRIS does not expose everything needed by the UI, particularly the mpv playlist.

The backend therefore communicates directly with mpv through a Unix socket:

```text
/tmp/mpv-socket
```

The mpv configuration enables this with:

```text
input-ipc-server=/tmp/mpv-socket
```

The backend uses this socket to:

- retrieve the mpv playlist
- determine the current playlist index
- retrieve the current file
- select a playlist item

## Files

```text
.
├── media-backend.py
├── media-title.qml
├── media-play-pause.qml
├── media-prev.qml
├── media-next.qml
└── mpv.conf
```

### `media-backend.py`

The main backend.

It provides three modes:

```bash
python3 media-backend.py daemon
python3 media-backend.py state
python3 media-backend.py command <action>
```

Available commands:

```text
play-pause
previous
next
play-index
play-track
seek
select-source
```

The `daemon` mode continuously publishes JSON state on stdout and accepts JSON commands through stdin.

Example state:

```json
{
  "available": true,
  "playing": true,
  "title": "Song",
  "artist": "Artist",
  "album": "Album",
  "position": 42,
  "duration": 210,
  "playlistPos": 2,
  "art": "file:///path/to/cover.jpg",
  "queue": [],
  "hasQueue": true,
  "source": "mpv",
  "isLocal": true,
  "sources": []
}
```

### `media-title.qml`

The main media module.

It displays the current title and artist and opens an interactive popup containing:

- source selection
- album artwork
- title and artist
- playback position
- seek bar
- previous/play-pause/next controls
- mpv queue
- queue item selection

The module communicates with the backend daemon through JSON over stdin/stdout.

### `media-play-pause.qml`

Standalone play/pause button.

It periodically queries the backend for the selected player's state and sends:

```text
command play-pause
```

when clicked.

The button performs an optimistic UI update so the icon changes immediately while the backend processes the command.

### `media-prev.qml`

Standalone previous-track button.

It sends:

```text
command previous
```

to the backend.

### `media-next.qml`

Standalone next-track button.

It sends:

```text
command next
```

to the backend.

### `mpv.conf`

Enables mpv's IPC socket:

```text
input-ipc-server=/tmp/mpv-socket
```

and enables exact automatic cover-art matching:

```text
cover-art-auto=exact
```

## Requirements

- Omarchy
- Quickshell
- Python 3
- `playerctl`
- Python D-Bus bindings (`dbus-python`, packaged as `python-dbus` on Arch) for kew TrackList access
- mpv
- An MPRIS-compatible media player

## Installation (specific for Omarchy)

Copy the modules into your Omarchy bar modules directory:

```bash
cp media-backend.py ~/.config/omarchy/bar/modules/
cp media-title.qml ~/.config/omarchy/bar/modules/
cp media-play-pause.qml ~/.config/omarchy/bar/modules/
cp media-prev.qml ~/.config/omarchy/bar/modules/
cp media-next.qml ~/.config/omarchy/bar/modules/
```

Make the backend executable if desired:

```bash
chmod +x ~/.config/omarchy/bar/modules/media-backend.py
```

Ensure mpv has the IPC configuration:

```text
input-ipc-server=/tmp/mpv-socket
cover-art-auto=exact
```

The QML modules currently expect the backend at:

```text
~/.config/omarchy/bar/modules/media-backend.py
```

## Backend configuration

The backend supports environment-variable overrides:

```bash
MPV_SOCKET=/tmp/mpv-socket
MPV_MEDIA_SELECTION=/tmp/mpv-media-selected
```

The default values are:

```text
MPV_SOCKET=/tmp/mpv-socket
MPV_MEDIA_SELECTION=/tmp/mpv-media-selected
```

## How it works

When the bar starts, the media module launches the backend:

```text
QML
 │
 │ python3 media-backend.py daemon
 ▼
Backend
 │
 ├── playerctl → discover MPRIS players
 │
 └── mpv socket → retrieve mpv queue
```

The backend continuously emits updated state as JSON.

When the user clicks a control:

```text
QML
 │
 │ {"action":"next","args":[]}
 ▼
Python backend
 │
 ▼
playerctl
 │
 ▼
Media player
```

For an mpv queue item:

```text
QML
 │
 │ {"action":"play-index","args":[3]}
 ▼
Python backend
 │
 ▼
mpv IPC socket
 │
 ▼
playlist-play-index
```

## License

MIT
