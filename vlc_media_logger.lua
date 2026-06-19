-- =============================================================================
-- vlc_media_logger.lua  v1.2.0
-- Logs watched movies and TV shows to Google Sheets via a Google Apps Script
-- webhook. Detects media type (TV / Movie / Unknown), supports directory
-- exclusions, and auto-detects OS for the local log file path.
--
-- Install:
--   Windows: %APPDATA%\vlc\lua\extensions\vlc_media_logger.lua
--            (from WSL: /mnt/c/Users/NAME/AppData/Roaming/vlc/lua/extensions/)
--   Linux:   ~/.local/share/vlc/lua/extensions/vlc_media_logger.lua
--   macOS:   ~/Library/Application Support/org.videolan.vlc/lua/extensions/
--
-- Activate: VLC → View → VLC Media Logger
-- =============================================================================

-- ─── OS DETECTION ─────────────────────────────────────────────────────────────

local function detect_os()
    -- package.config's first line is the directory separator
    if package.config:sub(1, 1) == "\\" then
        return "windows"
    end
    -- Distinguish macOS from Linux by a file only macOS has
    local f = io.open("/System/Library/CoreServices/SystemVersion.plist", "r")
    if f then
        f:close()
        return "mac"
    end
    return "linux"
end

local OS = detect_os()

-- ─── USER CONFIGURATION ───────────────────────────────────────────────────────

-- Deployment URL is loaded from vlc_media_logger.cfg (next to this file).
-- See vlc_media_logger.cfg.example for the expected format.
-- Never hardcode the URL here — the .cfg file is gitignored.
local function load_config()
    local src = debug.getinfo(1, "S").source:sub(2)
    local dir = src:match("^(.*[/\\])") or ""
    local f = io.open(dir .. "vlc_media_logger.cfg", "r")
    if not f then return {} end
    local cfg = {}
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)%s*=%s*(.+)$")
        if k then cfg[k] = v end
    end
    f:close()
    return cfg
end

local _cfg = load_config()
local APPS_SCRIPT_URL = _cfg.APPS_SCRIPT_URL or ""

-- Directories to EXCLUDE from logging (case-insensitive substring match).
-- Any path containing one of these strings will be silently ignored.
local EXCLUDED_DIRS = {
    "/music/",
    "/audiobooks/",
    "/podcasts/",
    "/tmp/",
}

-- TV detection: if the file path/name contains any of these strings
-- (case-insensitive) the entry is tagged as "TV Show".
local TV_PATH_HINTS = {
    "/Downloads",
    "/tv/",
    "/Serier - Kanske/",
    "/TV-serier/",
    "/tv show",
    "/series/",
    "/episodes/",
    "season",
    -- Note: bare "s0"–"s9" removed — too broad (matches paths like /storage/, /s0meuser/).
    -- SxxExx episode pattern (e.g. S01E04) is caught by the regex in detect_type().
}

-- Movie detection path hints.
local MOVIE_PATH_HINTS = {
    "/Downloads",
    "/movies/",
    "/Movies/", 
    "/movie/",
    "/films/",
    "/film/",
    "/cinema/",
}

-- Minimum playback percentage (0–100) before an entry is logged.
-- Avoids logging accidental one-second opens. Set to 0 to log immediately.
local MIN_PLAY_PERCENT = 5

-- Local log file path — auto-selected by OS.
-- Set to "" to disable local logging entirely.
local LOCAL_LOG_FILE = ({
    windows = "C:/temp/vlc_media_log.txt",
    mac     = os.getenv("HOME") .. "/tmp/vlc_media_log.txt",
    linux   = os.getenv("HOME") .. "/.local/share/vlc/media_log.txt",
})[OS]

-- ─── END OF USER CONFIGURATION ────────────────────────────────────────────────

local logged_this_item = false
local current_uri      = ""
local poll_timer       = nil

-- ─── DESCRIPTOR ───────────────────────────────────────────────────────────────

function descriptor()
    return {
        title        = "VLC Media Logger",
        version      = "1.2.0",
        author       = "b0red / Claude",
        url          = "",
        description  = "Logs watched movies and TV shows to Google Sheets.",
        capabilities = { "input-listener" },
    }
end

-- ─── LIFECYCLE ────────────────────────────────────────────────────────────────

function activate()
    vlc.msg.info("[MediaLogger] activated — OS detected: " .. OS)
    vlc.msg.info("[MediaLogger] log file: " .. (LOCAL_LOG_FILE ~= "" and LOCAL_LOG_FILE or "disabled"))
    ensure_log_dir()
    local ok, t = pcall(vlc.timer, poll_position)
    if ok then poll_timer = t end
end

function deactivate()
    if poll_timer then poll_timer:cancel() end
    vlc.msg.info("[MediaLogger] deactivated")
end

function close()
    vlc.deactivate()
end

-- ─── INPUT LISTENER ───────────────────────────────────────────────────────────

-- Called whenever the current input changes (new file, stop, etc.)
function input_changed()
    local input = vlc.input.item()

    if input == nil then
        logged_this_item = false
        current_uri      = ""
        if poll_timer then poll_timer:cancel() end
        return
    end

    local uri = input:uri() or ""
    if uri ~= current_uri then
        logged_this_item = false
        current_uri      = uri
        if poll_timer then poll_timer:cancel() end
    end
end

-- Called on play/pause/stop state changes.
-- VLC state integers: 3 = playing.
-- NOTE: this fires only on transitions — not on every tick — so we cannot
-- rely on position being >= MIN_PLAY_PERCENT at the moment it first fires
-- (position is ~0 at playback start). A timer polls position after a delay.
function playing_changed(state)
    if state ~= 3 then return end
    if logged_this_item then return end
    if poll_timer then
        poll_timer:cancel()
        poll_timer:schedule(3000000)  -- check position in 3 s
    else
        try_log()  -- fallback if timer API unavailable
    end
end

-- Timer callback: check whether MIN_PLAY_PERCENT has been reached yet.
function poll_position()
    if logged_this_item or current_uri == "" then return end
    if not try_log() and poll_timer then
        poll_timer:schedule(10000000)  -- not there yet — retry in 10 s
    end
end

-- Shared logging attempt. Returns true if the item was logged (or skipped
-- intentionally), false if we should try again later.
function try_log()
    if logged_this_item then return true end
    local input = vlc.input.item()
    if input == nil then return false end
    if get_play_position() < MIN_PLAY_PERCENT then return false end
    local uri   = input:uri() or ""
    local title = derive_title(input, uri)
    if not title or title == "" then return false end
    if is_excluded(uri) then
        vlc.msg.info("[MediaLogger] skipping excluded path: " .. uri)
        return true
    end
    log_entry(title, uri, detect_type(uri, title))
    logged_this_item = true
    return true
end

-- ─── HELPERS ──────────────────────────────────────────────────────────────────

-- Returns current playback position as a percentage (0–100).
function get_play_position()
    local ok, pos = pcall(function()
        return vlc.var.get(vlc.object.input(), "position") * 100
    end)
    return (ok and pos) and pos or 0
end

-- Derives a clean human-readable title from metadata or the filename.
function derive_title(input, uri)
    local meta = input:metas()
    if meta and meta["title"] and meta["title"] ~= "" then
        return meta["title"]
    end

    local filename = uri:match("([^/\\]+)$") or uri
    -- URL-decode common sequences
    filename = filename:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    -- Strip extension
    filename = filename:gsub("%.[^%.]+$", "")
    -- Replace dots/underscores with spaces
    filename = filename:gsub("[%._]+", " ")
    -- Trim whitespace
    return filename:match("^%s*(.-)%s*$")
end

-- Returns true if the URI matches any exclusion pattern.
function is_excluded(uri)
    local lower = uri:lower()
    for _, pattern in ipairs(EXCLUDED_DIRS) do
        if lower:find(pattern:lower(), 1, true) then
            return true
        end
    end
    return false
end

-- Detects media type: "TV Show", "Movie", or "Unknown".
function detect_type(uri, title)
    local lower = (uri .. " " .. title):lower()

    for _, hint in ipairs(TV_PATH_HINTS) do
        if lower:find(hint:lower(), 1, true) then
            return "TV Show"
        end
    end
    -- SxxExx pattern (e.g. S01E04)
    if lower:match("s%d%d?e%d%d") then
        return "TV Show"
    end

    for _, hint in ipairs(MOVIE_PATH_HINTS) do
        if lower:find(hint:lower(), 1, true) then
            return "Movie"
        end
    end
    -- Year in parentheses → likely a movie (e.g. "Dune (2021)")
    if uri:match("%(19%d%d%)") or uri:match("%(20%d%d%)") then
        return "Movie"
    end

    return "Unknown"
end

-- Fires the actual logging: HTTP request + optional local file.
function log_entry(title, uri, media_type)
    local timestamp = os.date("%Y-%m-%dT%H:%M:%S")
    vlc.msg.info("[MediaLogger] logging → " .. title .. " [" .. media_type .. "] OS=" .. OS)

    local url = APPS_SCRIPT_URL
        .. "?title="     .. url_encode(title)
        .. "&type="      .. url_encode(media_type)
        .. "&uri="       .. url_encode(uri)
        .. "&timestamp=" .. url_encode(timestamp)

    local cmd
    if OS == "windows" then
        -- Run curl.exe directly. Double-quoting the URL protects & in query params
        -- from cmd.exe interpretation. This call blocks briefly (~1 s) but is
        -- the only approach that works reliably without a helper script.
        cmd = 'curl.exe -s --max-time 10 "' .. url .. '" > nul 2>&1'
    else
        cmd = 'curl -s --max-time 10 "' .. url .. '" > /dev/null 2>&1 &'
    end
    os.execute(cmd)

    -- Optional local log file
    if LOCAL_LOG_FILE and LOCAL_LOG_FILE ~= "" then
        local f = io.open(LOCAL_LOG_FILE, "a")
        if f then
            f:write(timestamp .. "\t" .. media_type .. "\t" .. title .. "\t" .. uri .. "\n")
            f:close()
        end
    end
end

-- Creates the local log directory if it doesn't exist.
function ensure_log_dir()
    if not LOCAL_LOG_FILE or LOCAL_LOG_FILE == "" then return end

    local dir = LOCAL_LOG_FILE:match("^(.*)[/\\][^/\\]+$")
    if not dir then return end

    if OS == "windows" then
        os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '"')
    else
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
end

-- Basic URL percent-encoding.
function url_encode(str)
    if str == nil then return "" end
    str = tostring(str)
    str = str:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str:gsub(" ", "+")
end
