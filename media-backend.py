import json
import os
import select
import socket
import subprocess
import sys
import time
import dbus

SOCKET = os.environ.get("MPV_SOCKET", "/tmp/mpv-socket")
SELECTION_FILE = os.environ.get("MPV_MEDIA_SELECTION", "/tmp/mpv-media-selected")
ART_EXTENSIONS = (".jpg", ".jpeg", ".png", ".webp", ".avif")
SEP = "\x1f"
FORMAT = SEP.join([
  "{{status}}", "{{playerName}}", "{{title}}", "{{artist}}",
  "{{album}}", "{{mpris:artUrl}}", "{{position}}", "{{mpris:length}}"
])
# Players whose MPRIS names start with one of these are treated as "web" sources (browser tabs) 
# and are deprioritized in favor of local/native players such as mpv, vlc, kew, spotify, etc.
BROWSER_PREFIXES = (
  "chromium", "chrome", "firefox", "brave", "edge", "opera",
  "vivaldi", "librewolf", "waterfox", "epiphany", "midori"
)
EMPTY_STATE = {
  "available": False, "playing": False, "title": "", "artist": "",
  "album": "", "position": 0, "duration": 0, "playlistPos": -1, "path": "",
  "art": "", "queue": [], "hasQueue": False, "source": "", "isLocal": False,
  "sources": []
}


def playerctl_call(args, timeout=0.4):
  try:
    result = subprocess.run(["playerctl"] + args, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
      return None
    return result.stdout.strip()
  except Exception:
    return None


def playerctl_call_lines(args, timeout=0.4):
  try:
    result = subprocess.run(["playerctl"] + args, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
      return []
    return [line for line in result.stdout.split("\n") if line.strip()]
  except Exception:
    return []


def is_local_player(name):
  base = (name or "").split(".")[0].lower()
  return not any(base.startswith(prefix) for prefix in BROWSER_PREFIXES)


def friendly_name(name):
  base = (name or "").split(".")[0]
  known = {
    "mpv": "mpv", "vlc": "VLC", "kew": "kew", "spotify": "Spotify",
    "chromium": "Chrome", "chrome": "Chrome", "firefox": "Firefox",
    "brave": "Brave", "edge": "Edge", "opera": "Opera", "vivaldi": "Vivaldi",
    "librewolf": "LibreWolf", "waterfox": "Waterfox", "mplayer": "MPlayer",
    "audacious": "Audacious", "rhythmbox": "Rhythmbox", "clementine": "Clementine"
  }
  return known.get(base.lower(), base.capitalize() if base else "Player")


def parse_players():
  """Return metadata for every active MPRIS player, one entry each,
  excluding stopped/idle players that would otherwise leak an empty
  'Nothing playing' state into the UI."""
  lines = playerctl_call_lines(["-a", "metadata", "--format", FORMAT])
  players = []
  for line in lines:
    parts = line.split(SEP)
    while len(parts) < 8:
      parts.append("")
    status, player_name, title, artist, album, art_url, position_raw, length_raw = parts[:8]
    if not player_name:
      continue
    if status not in ("Playing", "Paused"):
      continue
    players.append({
      "status": status, "playerName": player_name, "title": title,
      "artist": artist, "album": album, "artUrl": art_url,
      "position": position_raw, "length": length_raw
    })
  return players


def priority_score(player):
  local = is_local_player(player["playerName"])
  playing = player["status"] == "Playing"
  if local and playing:
    return 0
  if local and not playing:
    return 1
  if (not local) and playing:
    return 2
  return 3


def read_selection():
  try:
    with open(SELECTION_FILE) as handle:
      value = handle.read().strip()
      return value or None
  except Exception:
    return None


def write_selection(name):
  try:
    if not name or name == "auto":
      if os.path.exists(SELECTION_FILE):
        os.remove(SELECTION_FILE)
    else:
      with open(SELECTION_FILE, "w") as handle:
        handle.write(name)
  except Exception:
    pass


def pick_player(players, preferred=None):
  if not players:
    return None
  if preferred:
    match = None
    for player in players:
      if player["playerName"] == preferred:
        match = player
        break
    if match:
      if is_local_player(match["playerName"]):
        # A pin on a local/native player always holds, playing or paused,
        # so you can freely switch over to inspect or control any of them
        # (e.g. pause one and browse another without it snapping back).
        return match
      # A pin on a web/browser source holds too, but only until a local
      # player starts actively playing - then local reclaims focus
      # automatically instead of a paused browser tab hogging it forever.
      if match["status"] == "Playing":
        return match
      other_local_playing = any(
        is_local_player(p["playerName"]) and p["status"] == "Playing"
        for p in players if p is not match
      )
      if not other_local_playing:
        return match
    # pinned player is gone, or a local player just took priority back
    write_selection(None)
  return min(players, key=priority_score)


def resolve_target():
  return pick_player(parse_players(), read_selection())


def switch_source(name):
  """Switch the active/displayed source to `name` (or back to automatic priority if name is falsy/"auto"),
  pausing whatever was previously showing if it was mid-playback."""
  previous = resolve_target()
  write_selection(name)
  new_target = resolve_target()
  if previous and previous["status"] == "Playing":
    if not new_target or new_target["playerName"] != previous["playerName"]:
      playerctl_call(["-p", previous["playerName"], "pause"])


def find_art(path):
  if not path or "://" in path:
    return ""
  path = os.path.expanduser(path)
  if not os.path.isfile(path):
    return ""
  directory = os.path.dirname(path)
  stem = os.path.splitext(os.path.basename(path))[0]
  candidates = []
  for ext in ART_EXTENSIONS:
    candidates.append(os.path.join(directory, stem + ext))
  for name in ("cover", "Cover", "folder", "Folder", "front", "Front", "AlbumArt", "albumart"):
    for ext in ART_EXTENSIONS:
      candidates.append(os.path.join(directory, name + ext))
  for candidate in candidates:
    if os.path.isfile(candidate):
      return "file://" + candidate
  return ""


def mpv_request(command, timeout=0.2):
  try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(SOCKET)
    sock.sendall((json.dumps({"command": command, "request_id": 1}) + "\n").encode())
    deadline = time.monotonic() + timeout
    buffer = b""
    while time.monotonic() < deadline:
      remaining = max(0.01, deadline - time.monotonic())
      readable, _, _ = select.select([sock], [], [], remaining)
      if not readable:
        continue
      chunk = sock.recv(65536)
      if not chunk:
        break
      buffer += chunk
      while b"\n" in buffer:
        line, buffer = buffer.split(b"\n", 1)
        try:
          response = json.loads(line.decode())
        except json.JSONDecodeError:
          continue
        if response.get("request_id") == 1:
          sock.close()
          if response.get("error") != "success":
            return None
          return response.get("data")
    sock.close()
  except Exception:
    print("mpv error") 
  return None


def mpv_send(command, timeout=0.2):
  try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(SOCKET)
    sock.sendall((json.dumps({"command": command, "request_id": 0}) + "\n").encode())
    sock.close()
    return True
  except Exception:
    return False


def get_mpv_queue():
  playlist = mpv_request(["get_property", "playlist"])
  if playlist is None:
    return [], -1, None
  path = mpv_request(["get_property", "path"])
  pos = mpv_request(["get_property", "playlist-pos"])
  current = -1 if pos is None else int(pos)
  items = []
  for index, item in enumerate(playlist):
    if not isinstance(item, dict):
      continue
    item_path = item.get("filename") or ""
    item_title = item.get("title") or os.path.splitext(os.path.basename(item_path))[0] or item_path
    items.append({"index": index, "title": item_title, "path": item_path, "current": index == current})
  return items, current, path


def get_mpris_tracklist(player_name):
  """Read a TrackList-capable player's ordered tracks and current track ID."""
  try:
    bus_name = player_name
    if not bus_name.startswith("org.mpris.MediaPlayer2."):
      bus_name = "org.mpris.MediaPlayer2." + bus_name
    obj = dbus.SessionBus().get_object(bus_name, "/org/mpris/MediaPlayer2")
    properties = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
    tracklist = dbus.Interface(obj, "org.mpris.MediaPlayer2.TrackList")
    track_ids = properties.Get("org.mpris.MediaPlayer2.TrackList", "Tracks")
    current_metadata = properties.Get("org.mpris.MediaPlayer2.Player", "Metadata")
    current_id = str(current_metadata.get("mpris:trackid", ""))
    metadata_list = tracklist.GetTracksMetadata(track_ids)
    items = []
    current_index = -1
    for index, metadata in enumerate(metadata_list):
      track_id = str(metadata.get("mpris:trackid", track_ids[index]))
      title = str(metadata.get("xesam:title", ""))
      url = str(metadata.get("xesam:url", ""))
      if not title:
        title = os.path.basename(url.split("?", 1)[0]) or url or "Unknown track"
      is_current = track_id == current_id
      if is_current:
        current_index = index
      items.append({
        "index": index, "trackId": track_id, "title": title,
        "path": url, "current": is_current
      })
    return items, current_index
  except Exception:
    return [], -1


def mpris_goto(player_name, track_id):
  try:
    bus_name = player_name
    if not bus_name.startswith("org.mpris.MediaPlayer2."):
      bus_name = "org.mpris.MediaPlayer2." + bus_name
    obj = dbus.SessionBus().get_object(bus_name, "/org/mpris/MediaPlayer2")
    tracklist = dbus.Interface(obj, "org.mpris.MediaPlayer2.TrackList")
    tracklist.GoTo(dbus.ObjectPath(track_id))
    return True
  except Exception:
    return False


def to_seconds(value):
  try:
    return max(0.0, float(value) / 1000000)
  except (TypeError, ValueError):
    return 0.0


def build_state():
  players = parse_players()
  if not players:
    return dict(EMPTY_STATE)

  preferred = read_selection()
  chosen = pick_player(players, preferred)
  if chosen is None:
    return dict(EMPTY_STATE)

  is_mpv = chosen["playerName"].startswith("mpv")
  queue = []
  playlist_pos = -1
  art = chosen["artUrl"] or ""
  if is_mpv:
    queue, playlist_pos, mpv_path = get_mpv_queue()
    if not art:
      art = find_art(mpv_path)
  elif chosen["playerName"].split(".")[0].lower() == "kew":
    queue, playlist_pos = get_mpris_tracklist(chosen["playerName"])

  sources = []
  seen = set()
  for player in players:
    if player["playerName"] in seen:
      continue
    seen.add(player["playerName"])
    sources.append({
      "name": player["playerName"],
      "label": friendly_name(player["playerName"]),
      "title": player["title"] or friendly_name(player["playerName"]),
      "artist": player["artist"],
      "playing": player["status"] == "Playing",
      "isLocal": is_local_player(player["playerName"]),
      "selected": player["playerName"] == chosen["playerName"]
    })

  return {
    "available": True,
    "playing": chosen["status"] == "Playing",
    "title": chosen["title"] or friendly_name(chosen["playerName"]),
    "artist": chosen["artist"],
    "album": chosen["album"],
    "position": to_seconds(chosen["position"]),
    "duration": to_seconds(chosen["length"]),
    "playlistPos": playlist_pos,
    "path": "",
    "art": art,
    "queue": queue,
    "hasQueue": len(queue) > 0,
    "source": chosen["playerName"],
    "isLocal": is_local_player(chosen["playerName"]),
    "sources": sources,
    "autoSelected": preferred is None
  }


def do_transport(action_name):
  target = resolve_target()
  if target:
    return playerctl_call(["-p", target["playerName"], action_name])
  return playerctl_call([action_name])


def do_seek(position_seconds):
  target = resolve_target()
  if target:
    return playerctl_call(["-p", target["playerName"], "position", str(position_seconds)])
  return playerctl_call(["position", str(position_seconds)])


def daemon():
  last_emit = None
  while True:
    state = build_state()
    compact = json.dumps(state, separators=(",", ":"))
    if compact != last_emit:
      print(compact, flush=True)
      last_emit = compact
    readable, _, _ = select.select([sys.stdin], [], [], 0.5)
    if sys.stdin in readable:
      line = sys.stdin.readline()
      if not line:
        return
      try:
        message = json.loads(line)
        action = message.get("action")
        args = message.get("args", [])
        if action == "play-index":
          if state.get("hasQueue"):
            mpv_send(["playlist-play-index", int(args[0])])
            mpv_send(["set_property", "pause", False])
        elif action == "play-track":
          if len(args) >= 2:
            mpris_goto(args[1], args[0])
        elif action == "seek":
          do_seek(float(args[0]))
        elif action == "play-pause":
          do_transport("play-pause")
        elif action == "previous":
          do_transport("previous")
        elif action == "next":
          do_transport("next")
        elif action == "select-source":
          switch_source(args[0] if args else None)
      except Exception:
        pass


def command_once(action, args):
  if action == "play-index" and len(args) == 1:
    mpv_send(["playlist-play-index", int(args[0])])
    mpv_send(["set_property", "pause", False])
    return 0
  if action == "play-track" and len(args) == 2:
    return 0 if mpris_goto(args[1], args[0]) else 1
  if action == "seek" and len(args) == 1:
    return 0 if do_seek(float(args[0])) is not None else 1
  if action in ("play-pause", "previous", "next"):
    return 0 if do_transport(action) is not None else 1
  if action == "select-source":
    switch_source(args[0] if args else None)
    return 0
  return 1


if __name__ == "__main__":
  if len(sys.argv) > 1 and sys.argv[1] == "daemon":
    daemon()
  elif len(sys.argv) > 1 and sys.argv[1] == "state":
    print(json.dumps(build_state(), separators=(",", ":")))
  elif len(sys.argv) > 1 and sys.argv[1] == "command" and len(sys.argv) > 2:
    sys.exit(command_once(sys.argv[2], sys.argv[3:]))
  else:
    print("usage: media-backend.py daemon | state | command <play-pause|previous|next|play-index|play-track|seek|select-source>")
