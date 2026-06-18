-- =============================================================================
-- vlc_media_logger.lua
-- Logs the currently playing media to Google Sheets via a Google Apps Script
-- webhook. Detects media type (TV / Movie / Unknown) and supports directory
-- exclusions.
--
-- Install:
--   Linux:   ~/.local/share/vlc/lua/extensions/vlc_media_logger.lua
--   Windows: %APPDATA%\vlc\lua\extensions\vlc_media_logger.lua
--   macOS:   ~/Library/Application Support/org.videolan.vlc/lua/extensions/
--
-- Activate: VLC → View → VLC Media Logger
-- =============================================================================

-- ─── USER CONFIGURATION ──────────────────────────────────────────────────────

-- Your deployed Google Apps Script web app URL.
-- See the companion Apps Script file for setup instructions.
local APPS_SCRIPT_URL = "https://script.google.com/macros/s/AKfycbxFut6jL2oLXn9b6PmZrA_R1NbXFl1BT3S2WdmvjqO4c6pd2FGLRuXppbOfK7QQlod_Iw/exec"

-- Directories to EXCLUDE from logging (case-insensitive substring match).
-- Any path containing one of these strings will be silently ignored.
local EXCLUDED_DIRS = {
    "/music/",
    "/audiobooks/",
    "/podcasts/",
    "/tmp/",
    "downloads/",   -- scratch downloads you don't want tracked
}

-- TV detection: if the file path contains any of these strings (case-insensitive)
-- the entry is tagged as "TV Show".
local TV_PATH_HINTS = {
    "/tv/",
    "/tv show",
    "/series/",
    "/episodes/",
    "season",       -- e.g. /Season 01/
    "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9",  -- S01E02 pattern
}

-- Movie detection path hints.
local MOVIE_PATH_HINTS = {
    "/movies/",
    "/movie/",
    "/films/",
    "/film/",
    "/cinema/",
}

-- Minimum playback percentage before the entry is logged (0–100).
-- Set to 0 to log immediately on play start.
-- Set e.g. to 5 to avoid logging accidental one-second opens.
local MIN_PLAY_PERCENT = 5

-- Log a plain-text local file as well (useful for debugging).
-- Set to "" to disable.
local LOCAL_LOG_FILE = os.getenv("HOME") .. "/.local/share/vlc/media_log.txt"

-- ─── END OF USER CONFIGURATION ───────────────────────────────────────────────

local logged_this_item = false  -- prevent duplicate logs per playback session
local current_uri      = ""

-- ─── DESCRIPTOR ──────────────────────────────────────────────────────────────

function descriptor()
    return {
        title       = "VLC Media Logger",
        version     = "1.0.0",
        author      = "b0red / Claude",
        url         = "",
        description = "Logs watched movies and TV shows to Google Sheets.",
        capabilities = { "input-listener" },
    }
end

-- ─── LIFECYCLE ───────────────────────────────────────────────────────────────

function activate()
    vlc.msg.info("[MediaLogger] activated")
end

function deactivate()
    vlc.msg.info("[MediaLogger] deactivated")
end

function close()
    vlc.deactivate()
end

-- ─── INPUT LISTENER ──────────────────────────────────────────────────────────

-- Called whenever the current input changes (new file opened, stopped, etc.)
function input_changed()
    local input = vlc.input.item()

    if input == nil then
        -- Playback stopped; reset state
        logged_this_item = false
        current_uri      = ""
        return
    end

    local uri = input:uri() or ""

    if uri ~= current_uri then
        -- New item started
        logged_this_item = false
        current_uri      = uri
    end
end

-- Called on play/pause/stop state changes — we use this to check progress.
function playing_changed()
    if logged_this_item then return end

    local input = vlc.input.item()
    if input == nil then return end

    -- Check playback position
    local pos = get_play_position()
    if pos < MIN_PLAY_PERCENT then return end

    local uri   = input:uri() or ""
    local title = derive_title(input, uri)

    if title == "" or title == nil then return end
    if is_excluded(uri) then
        vlc.msg.info("[MediaLogger] skipping excluded path: " .. uri)
        return
    end

    local media_type = detect_type(uri, title)
    log_entry(title, uri, media_type)
    logged_this_item = true
end

-- ─── HELPERS ─────────────────────────────────────────────────────────────────

-- Returns current playback position as a percentage (0–100).
function get_play_position()
    local ok, pos = pcall(function()
        return vlc.var.get(vlc.object.input(), "position") * 100
    end)
    if ok and pos then return pos else return 0 end
end

-- Derives a clean human-readable title from item metadata or filename.
function derive_title(input, uri)
    -- Try metadata title first
    local meta = input:metas()
    if meta and meta["title"] and meta["title"] ~= "" then
        return meta["title"]
    end

    -- Fall back to filename without extension
    local filename = uri:match("([^/\\]+)$") or uri
    -- URL-decode common sequences
    filename = filename:gsub("%%20", " ")
                       :gsub("%%28", "(")
                       :gsub("%%29", ")")
                       :gsub("%%5B", "[")
                       :gsub("%%5D", "]")
    -- Strip extension
    filename = filename:gsub("%.[^%.]+$", "")
    -- Replace dots/underscores with spaces (common in filenames)
    filename = filename:gsub("[%._]+", " ")
    -- Trim
    filename = filename:match("^%s*(.-)%s*$")
    return filename
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
    local lower = uri:lower()

    -- Check TV hints first (more specific)
    for _, hint in ipairs(TV_PATH_HINTS) do
        if lower:find(hint:lower(), 1, true) then
            return "TV Show"
        end
    end
    -- SxxExx pattern in title or path (e.g. S01E04)
    if lower:match("s%d%d?e%d%d") then
        return "TV Show"
    end

    -- Check movie hints
    for _, hint in ipairs(MOVIE_PATH_HINTS) do
        if lower:find(hint:lower(), 1, true) then
            return "Movie"
        end
    end

    -- Heuristic: if path contains a 4-digit year in parentheses → likely movie
    if uri:match("%(19%d%d%)") or uri:match("%(20%d%d%)") then
        return "Movie"
    end

    return "Unknown"
end

-- Fires the actual logging: HTTP call + optional local file.
function log_entry(title, uri, media_type)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    vlc.msg.info("[MediaLogger] logging → " .. title .. " [" .. media_type .. "]")

    -- Build the query string, URL-encoding the title and path
    local encoded_title = url_encode(title)
    local encoded_type  = url_encode(media_type)
    local encoded_uri   = url_encode(uri)
    local encoded_ts    = url_encode(timestamp)

    local url = APPS_SCRIPT_URL
        .. "?title="     .. encoded_title
        .. "&type="      .. encoded_type
        .. "&uri="       .. encoded_uri
        .. "&timestamp=" .. encoded_ts

    -- Use curl (available on Linux/macOS/WSL). The & runs it in background
    -- so VLC doesn't block.
    local cmd = 'curl -s --max-time 10 "' .. url .. '" > /dev/null 2>&1 &'
    os.execute(cmd)

    -- Optional: write to local log file
    if LOCAL_LOG_FILE and LOCAL_LOG_FILE ~= "" then
        local f = io.open(LOCAL_LOG_FILE, "a")
        if f then
            f:write(timestamp .. "\t" .. media_type .. "\t" .. title .. "\t" .. uri .. "\n")
            f:close()
        end
    end
end

-- Basic URL percent-encoding.
function url_encode(str)
    if str == nil then return "" end
    str = tostring(str)
    str = str:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end
