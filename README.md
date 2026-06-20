# VLC Media Logger

Logs watched movies and TV shows from VLC to a Google Sheet — automatically, in the background.

**Current version: v1.4.0** — Windows only

---

## How it works

```
VLC plays a file
  → Lua extension fires on meta_changed / playing_changed
  → Derives title from metadata (or filename fallback)
  → Strips quality/codec junk (720p, BluRay, x264, …)
  → Detects type: TV Show / Movie / Unknown
  → Appends a row to C:\temp\vlc_media_log.txt
  → curl GET → Google Apps Script web app
  → Row appended to Google Sheet (timestamp, title, type)
```

---

## Files

| File | Purpose |
|---|---|
| `vlc_media_logger.lua` | VLC Lua extension (runs inside VLC) |
| `vlc_media_logger.gs` | Google Apps Script (runs in Google Sheets) |
| `vlc_media_logger.cfg.example` | Config template — copy to `vlc_media_logger.cfg` and fill in your URL |
| `vlc_media_logger.cfg` | Your local config with real URL — **gitignored, never committed** |

---

## Setup — Google Sheets side (do this first)

1. Open (or create) a Google Sheet.
2. Go to **Extensions → Apps Script**.
3. Paste the full contents of `vlc_media_logger.gs`, replacing anything there.
4. Click **▶ Run → `setupSheet`** once. Accept permissions when prompted.
   This creates the *Watch Log* tab with a formatted header row and renames the spreadsheet to *VLC Media Log*.
5. Deploy as a web app:
   - **Deploy → New deployment**
   - Type: **Web app**
   - Execute as: **Me**
   - Who has access: **Anyone**
6. Copy the long deployment URL (looks like `https://script.google.com/macros/s/ABC123.../exec`).

> ⚠️ Every time you edit the `.gs` file, you must create a **New deployment** — editing an existing deployment doesn't update the live URL's code.

---

## Setup — VLC side (Windows)

1. Copy `vlc_media_logger.cfg.example` to `vlc_media_logger.cfg` in the same folder and paste your deployment URL:

```ini
APPS_SCRIPT_URL=https://script.google.com/macros/s/YOUR_DEPLOYMENT_ID/exec
```

2. Copy **both** `vlc_media_logger.lua` and `vlc_media_logger.cfg` to your VLC extensions folder:

```
%APPDATA%\vlc\lua\extensions\
```

> **Developing in WSL?** VLC cannot read from the WSL filesystem, so copy both files to the Windows path from WSL:
> ```bash
> cp ~/development/vlc_logger/vlc_media_logger.{lua,cfg} "/mnt/c/Users/YOUR_NAME/AppData/Roaming/vlc/lua/extensions/"
> ```
> A shell alias makes re-deploying painless:
> ```bash
> alias vlc-deploy='cp ~/development/vlc_logger/vlc_media_logger.{lua,cfg} "/mnt/c/Users/YOUR_NAME/AppData/Roaming/vlc/lua/extensions/"'
> ```

3. Restart VLC.
4. **View → VLC Media Logger** to activate.

The extension creates `C:\temp\` automatically if it doesn't exist.

---

## Title cleanup

Titles are derived from VLC's metadata. When the metadata title looks like a raw filename (e.g. `The.Show.S01E03.720p.WEB.x264-GROUP`), the extension:

1. Replaces dots and underscores with spaces.
2. Finds the first quality/codec marker (`720p`, `1080p`, `BluRay`, `WEBRip`, `x264`, `x265`, `HEVC`, `HDTV`, `DVDRip`, …) and strips it and everything after.

Result: `The Show S01E03`

---

## Media type detection

| Type | How it's detected |
|---|---|
| **TV Show** | URI matches `S01E02` pattern, or path contains `/tv/`, `/serier`, `/series/`, `/episodes/`, `season` |
| **Movie** | Filename contains a `(YYYY)` year, or path contains `/movies/`, `/films/`, `/film/`, `/cinema/` |
| **Unknown** | Neither of the above matched |

To add your own path hints, edit the `TV_HINTS` / `MOVIE_HINTS` tables at the top of `vlc_media_logger.lua`.

---

## Google Sheet columns

Configured in `vlc_media_logger.gs` via the `COLUMNS` array:

```js
const COLUMNS = ["timestamp", "title", "type"];
```

Reorder or remove columns freely — the header row is auto-generated to match. URI is intentionally excluded from the sheet (it stays in the local log file).

---

## Duplicate guard

The Apps Script skips logging if the same title was logged within `DEDUP_WINDOW_MINUTES` (default: 5 min). Useful if you pause/resume at the start of a file.

---

## Local log file

All activity is written to `C:\temp\vlc_media_log.txt`.

Format: `timestamp TAB type TAB title TAB uri`

Example:
```
2026-06-20T22:29:50	TV Show	the scream murder a true teen horror story s01e03	file:///X:/Serier%20-%20Kanske/...
```

Activation and deactivation events are also written with `[INFO]` markers.

---

## Troubleshooting

**Nothing appears in the sheet**
- Check VLC's Messages log (**Tools → Messages**) for `[MediaLogger]` lines.
- Test the URL directly in a browser: `https://script.google.com/.../exec?title=Test&type=Movie&uri=test&timestamp=2026-01-01`
- Confirm the Apps Script deployment is set to **Anyone** access.
- Check `C:\temp\vlc_media_log.txt` — if the title row is there but the sheet is empty, curl is the problem. Run the URL from a terminal: `curl.exe "https://script.google.com/.../exec?title=Test&type=Movie&timestamp=2026-01-01"`

**Duplicate rows**
- Increase `DEDUP_WINDOW_MINUTES` in the `.gs` file and redeploy.

**Extension doesn't appear in View menu**
- Make sure neither `vlc_media_logger.lua` nor `vlc_media_logger.cfg` calls `io.open` or `os.getenv` at module level — VLC's Lua sandbox silently drops extensions that do this.
- Confirm the file is in `%APPDATA%\vlc\lua\extensions\` (not a subdirectory).

---

## Changelog

**v1.4.0**
- Added `clean_title()`: strips quality/codec markers from filename-derived titles (720p, BluRay, WEBRip, x264, HEVC, …)
- Added `detect_type()`: classifies media as TV Show, Movie, or Unknown from path hints and SxxExx pattern
- `type` is now sent to Google Sheets; `uri` removed from sheet columns (kept in local log only)
- Removed verbose debug logging from the local log file

**v1.3.x**
- Simplified to Windows-only; removed OS detection and per-OS path selection
- Config (`APPS_SCRIPT_URL`) loaded inside `activate()` to satisfy VLC's Lua sandbox restrictions
- Added detailed debug logging to `C:\temp\vlc_media_log.txt` to confirm curl and Sheets connectivity
- `meta_changed` callback added alongside `playing_changed` for more reliable title capture

**v1.2.0**
- Deployment URL moved out of the script into `vlc_media_logger.cfg` (gitignored) — no secrets in version control
- Fixed: Windows curl now calls `curl.exe` directly, resolving `&` misinterpretation in the old `cmd /c` wrapper

**v1.1.0**
- Added OS detection (Windows / macOS / Linux)
- Local log file path auto-selected per OS; log directory created automatically if missing
- URL-decoding in title derivation handles all `%XX` sequences

**v1.0.0**
- Initial release
