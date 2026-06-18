# VLC Media Logger

Logs watched movies and TV shows from VLC to a Google Sheet — automatically, in the background.

**Current version: v1.1.0**

---

## How it works

```
VLC plays a file
  → Lua extension detects OS (Windows / macOS / Linux)
  → Detects it (after MIN_PLAY_PERCENT %)
  → Detects type: TV Show / Movie / Unknown
  → Checks exclusion list
  → curl GET  → Google Apps Script web app  (backgrounded, OS-appropriate)
  → Row appended to Google Sheet
  → Entry written to local log file (OS-appropriate path)
```

---

## Files

| File | Purpose |
|---|---|
| `vlc_media_logger.lua` | VLC Lua extension (runs inside VLC) |
| `vlc_media_logger.gs` | Google Apps Script (runs in Google Sheets) |

---

## Setup — Google Sheets side (do this first)

1. Open (or create) a Google Sheet.
2. Go to **Extensions → Apps Script**.
3. Paste the full contents of `vlc_media_logger.gs`, replacing anything there.
4. Click **▶ Run → `setupSheet`** once. Accept permissions when prompted.
   This creates the *Watch Log* tab with a formatted header row.
5. Deploy as a web app:
   - **Deploy → New deployment**
   - Type: **Web app**
   - Execute as: **Me**
   - Who has access: **Anyone**
6. Copy the long deployment URL (looks like `https://script.google.com/macros/s/ABC123.../exec`).

> ⚠️ Every time you edit the `.gs` file, you must create a **New deployment** — editing an existing deployment doesn't update the live URL's code.

---

## Setup — VLC side

1. Open `vlc_media_logger.lua` and edit the **USER CONFIGURATION** block at the top:

```lua
-- Paste your deployment URL here
local APPS_SCRIPT_URL = "https://script.google.com/macros/s/YOUR_ID/exec"

-- Directories to never log (case-insensitive substring match against full path)
local EXCLUDED_DIRS = {
    "/music/",
    "/audiobooks/",
    "/tmp/",
}

-- Minimum % of the file that must have played before logging
local MIN_PLAY_PERCENT = 5
```

2. Copy the file to your VLC extensions folder:

| OS | Path |
|---|---|
| Linux / WSL | `~/.local/share/vlc/lua/extensions/` |
| Windows | `%APPDATA%\vlc\lua\extensions\` |
| macOS | `~/Library/Application Support/org.videolan.vlc/lua/extensions/` |

> **Developing in WSL with Windows VLC?** VLC can't read from the WSL filesystem, so copy it to the Windows path from WSL:
> ```bash
> cp ~/development/vlc_logger/vlc_media_logger.lua "/mnt/c/Users/YOUR_NAME/AppData/Roaming/vlc/lua/extensions/"
> ```
> Add a shell alias to make re-deploying painless:
> ```bash
> alias vlc-deploy='cp ~/development/vlc_logger/vlc_media_logger.lua "/mnt/c/Users/YOUR_NAME/AppData/Roaming/vlc/lua/extensions/"'
> ```

3. Restart VLC.
4. **View → VLC Media Logger** to activate.

---

## Media type detection

| Type | How it's detected |
|---|---|
| **TV Show** | Path contains `/tv/`, `/series/`, `season`, or matches `S01E02` pattern |
| **Movie** | Path contains `/movies/`, `/films/`, or filename has a `(YYYY)` year |
| **Unknown** | Neither of the above matched |

You can add your own path hints in the `TV_PATH_HINTS` / `MOVIE_PATH_HINTS` arrays inside the Lua file.  
Example — your setup has `/media/TV/tv1` (active) and `/media/TV/tv2` (archive):

```lua
local TV_PATH_HINTS = {
    "/media/tv/",   -- catches both tv1 and tv2
    "season",
    "s0", "s1", ...
}
```

---

## Google Sheet columns

Configured in `vlc_media_logger.gs` via the `COLUMNS` array:

```js
const COLUMNS = ["timestamp", "title", "type", "uri"];
```

Reorder or remove columns freely — the header row is auto-generated to match.

---

## Duplicate guard

The Apps Script skips logging if the same title was logged within `DEDUP_WINDOW_MINUTES` (default: 5 min). Useful if you pause/resume at the start of a file.

---

## Local log file

The Lua extension auto-selects a log path based on the detected OS:

| OS | Path |
|---|---|
| Windows | `C:\temp\vlc_media_log.txt` |
| macOS | `~/tmp/vlc_media_log.txt` |
| Linux | `~/.local/share/vlc/media_log.txt` |

The directory is created automatically if it doesn't exist. Format: `timestamp \t type \t title \t uri`

Set `LOCAL_LOG_FILE = ""` to disable. You can also override the path manually by setting `LOCAL_LOG_FILE` directly in the config block instead of using the OS table.

On activate, VLC's Messages log (`Tools → Messages`) will confirm which OS was detected and which log path is in use.

---

## Troubleshooting

**Nothing appears in the sheet**
- Check VLC's Messages log (Tools → Messages) for `[MediaLogger]` lines.
- Make sure `MIN_PLAY_PERCENT` threshold has been passed.
- Test the URL directly in a browser: `https://script.google.com/.../exec?title=Test&type=Movie&uri=test&timestamp=2026-01-01`
- Confirm the Apps Script deployment is set to **Anyone** access.

**Duplicate rows**
- Increase `DEDUP_WINDOW_MINUTES` in the `.gs` file and redeploy.

**Windows users**
- curl is built into Windows 10+, no install needed.
- The script uses `start /B curl ...` to background the request (vs `&` on Unix) — this is handled automatically.
- If developing in WSL, always copy to the Windows extensions path — VLC cannot read from the WSL filesystem.

---

## Changelog

**v1.1.0**
- Added OS detection (Windows / macOS / Linux) via `package.config` separator + macOS plist check
- Local log file path now auto-selected per OS; log directory created automatically if missing
- Windows curl backgrounded with `start /B` instead of `&`
- URL-decoding in title derivation now handles all `%XX` sequences generically
- Type detection now checks both path and title string
- OS and log path confirmed in VLC Messages log on activate

**v1.0.0**
- Initial release