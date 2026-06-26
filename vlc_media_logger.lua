-- vlc_media_logger.lua  v1.5.0  (Windows)
-- Logs watched media to Google Sheets and C:\temp\vlc_media_log.txt
-- Install: %APPDATA%\vlc\lua\extensions\vlc_media_logger.lua
-- Activate: VLC > View > VLC Media Logger

local LOG_FILE        = "C:\\temp\\vlc_media_log.txt"
local SCRIPT_URL      = ""
local logged          = false
local last_uri        = ""
local play_started    = 0       -- os.time() when current item began playing
local WATCH_THRESHOLD = 15 * 60 -- seconds before a play event is logged

-- Path hints for type detection (matched against lower-case URI)
local TV_HINTS    = { "/tv/", "/serier", "/tv-serier", "/series/", "/episodes/", "season" }
local MOVIE_HINTS = { "/movies/", "/movie/", "/films/", "/film/", "/cinema/" }

-- Quality/codec markers whose presence (preceded by a space) signals junk in the title
local QUALITY_PATS = {
    "%d%d%d+[pP]",          -- 720p, 1080p, 2160p
    "[Xx]264", "[Xx]265",
    "[Hh][Ee][Vv][Cc]",
    "[Bb][Ll][Uu][Rr][Aa][Yy]",
    "[Bb][Dd][Rr][Ii][Pp]",
    "[Bb][Rr][Rr][Ii][Pp]",
    "[Ww][Ee][Bb][Rr][Ii][Pp]",
    "[Hh][Dd][Tt][Vv]",
    "[Dd][Vv][Dd][Rr][Ii][Pp]",
}

function descriptor()
    return {
        title        = "VLC Media Logger",
        version      = "1.5.0",
        author       = "b0red",
        url          = "",
        description  = "Logs watched movies and TV shows to Google Sheets.",
        capabilities = { "input-listener" },
    }
end

function activate()
    -- Load config inside activate() — io.open at module level silently breaks extension loading
    local appdata = os.getenv("APPDATA")
    if appdata then
        local f = io.open(appdata .. "\\vlc\\lua\\extensions\\vlc_media_logger.cfg", "r")
        if f then
            for line in f:lines() do
                local k, v = line:match("^([%w_]+)%s*=%s*(.+)$")
                if k == "APPS_SCRIPT_URL" then SCRIPT_URL = v end
            end
            f:close()
        end
    end

    os.execute("if not exist C:\\temp mkdir C:\\temp")

    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%Y-%m-%dT%H:%M:%S") .. "\t[INFO]\tactivated\n")
        f:close()
        vlc.msg.info("[MediaLogger] activated, log file OK")
    else
        vlc.msg.err("[MediaLogger] cannot write to " .. LOG_FILE)
    end
end

function deactivate()
    vlc.msg.info("[MediaLogger] deactivated")
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(os.date("%Y-%m-%dT%H:%M:%S") .. "\t[INFO]\tdeactivated\n")
        f:close()
    end
end

function close()
    vlc.deactivate()
end

function input_changed()
    local item = vlc.input.item()
    if item == nil then
        logged       = false
        last_uri     = ""
        play_started = 0
        return
    end
    local uri = item:uri() or ""
    if uri ~= last_uri then
        logged       = false
        last_uri     = uri
        play_started = 0
    end
end

function playing_changed(state)
    if state == 3 and play_started == 0 then
        play_started = os.time()
    end
    if logged then return end
    if play_started > 0 and (os.time() - play_started) >= WATCH_THRESHOLD then
        try_log()
    end
end

function meta_changed()
    if logged or last_uri == "" or play_started == 0 then return end
    if (os.time() - play_started) < WATCH_THRESHOLD then return end
    try_log()
end

function try_log()
    if logged then return end
    local item = vlc.input.item()
    if not item then return end
    local uri   = item:uri() or ""
    local title = get_title(item, uri)
    local mtype = detect_type(uri, title)
    vlc.msg.info("[MediaLogger] title=" .. tostring(title) .. " type=" .. mtype)
    if not title or title == "" then return end
    log_entry(title, uri, mtype)
    logged = true
end

-- Strips quality/codec/source markers and everything after them.
-- Input must already have dots replaced with spaces.
function clean_title(name)
    if not name or name == "" then return "" end
    local cutoff
    for _, pat in ipairs(QUALITY_PATS) do
        local pos = name:find("%s+" .. pat)
        if pos and (not cutoff or pos < cutoff) then cutoff = pos end
    end
    if cutoff then name = name:sub(1, cutoff - 1) end
    return name:match("^%s*(.-)%s*$") or ""
end

function get_title(item, uri)
    local meta = item:metas()
    if meta and meta["title"] and meta["title"] ~= "" then
        return clean_title(meta["title"])
    end
    local name = uri:match("([^/\\]+)$") or uri
    name = name:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    name = name:gsub("%.[^%.]+$", "")
    name = name:gsub("[%._]+", " ")
    return clean_title(name:match("^%s*(.-)%s*$") or "")
end

-- Returns "TV Show", "Movie", or "Unknown".
function detect_type(uri, title)
    local lower = uri:lower() .. " " .. (title or ""):lower()
    -- SxxExx pattern (S01E04) → TV Show
    if lower:match("s%d%d?e%d%d") then return "TV Show" end
    for _, hint in ipairs(TV_HINTS) do
        if lower:find(hint, 1, true) then return "TV Show" end
    end
    -- Year in parens → Movie (e.g. "Dune (2021)")
    if uri:match("%(2%d%d%d%)") or uri:match("%(19%d%d%)") then return "Movie" end
    for _, hint in ipairs(MOVIE_HINTS) do
        if lower:find(hint, 1, true) then return "Movie" end
    end
    return "Unknown"
end

-- Returns the Windows file path for a file:// URI, or nil for network/stream URIs.
function get_local_path(uri)
    local path = uri:match("^file:///(.+)$")
    if not path then return nil end
    return path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

-- Tries to locate a .nfo sidecar for the given media file path.
-- Search order: same-name.nfo → folder-name.nfo → movie.nfo → first *.nfo in dir.
function find_nfo_file(path)
    local function exists(p)
        local f = io.open(p, "r")
        if f then f:close(); return true end
        return false
    end

    local nfo = path:gsub("%.[^%.]+$", ".nfo")
    if exists(nfo) then return nfo end

    local dir = path:match("^(.+)[\\/][^\\/]+$")
    if not dir then return nil end

    local folder = dir:match("[^\\/]+$")
    if folder and exists(dir .. "/" .. folder .. ".nfo") then
        return dir .. "/" .. folder .. ".nfo"
    end
    if exists(dir .. "/movie.nfo") then return dir .. "/movie.nfo" end

    -- Fallback: scan directory. Brief console flash may appear (same as curl calls).
    local dir_win = dir:gsub("/", "\\")
    local pipe = io.popen('dir /b "' .. dir_win .. '\\*.nfo" 2>nul')
    if pipe then
        local line = pipe:read("*l")
        pipe:close()
        if line and line ~= "" then return dir .. "/" .. line end
    end
    return nil
end

-- Increments <playcount> and sets <watched>false</watched> → true in the NFO file.
function update_nfo(uri)
    local path = get_local_path(uri)
    if not path then return end

    local nfo_path = find_nfo_file(path)
    if not nfo_path then
        vlc.msg.info("[MediaLogger] no NFO file found alongside " .. path)
        return
    end

    local f = io.open(nfo_path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()

    local updated = content:gsub("(<playcount>)(%d+)(</playcount>)", function(o, n, c)
        return o .. (tonumber(n) + 1) .. c
    end)
    updated = updated:gsub("<watched>false</watched>", "<watched>true</watched>")

    if updated == content then
        vlc.msg.info("[MediaLogger] NFO has no playcount/watched tags: " .. nfo_path)
        return
    end

    local fw = io.open(nfo_path, "w")
    if fw then
        fw:write(updated)
        fw:close()
        vlc.msg.info("[MediaLogger] NFO updated: " .. nfo_path)
        local flog = io.open(LOG_FILE, "a")
        if flog then
            flog:write(os.date("%Y-%m-%dT%H:%M:%S") .. "\t[INFO]\tNFO updated: " .. nfo_path .. "\n")
            flog:close()
        end
    else
        vlc.msg.err("[MediaLogger] cannot write NFO: " .. nfo_path)
    end
end

function log_entry(title, uri, media_type)
    local ts = os.date("%Y-%m-%dT%H:%M:%S")

    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(ts .. "\t" .. media_type .. "\t" .. title .. "\t" .. uri .. "\n")
        f:close()
    else
        vlc.msg.err("[MediaLogger] cannot open log file")
    end

    if SCRIPT_URL ~= "" then
        local url = SCRIPT_URL
            .. "?title="     .. url_encode(title)
            .. "&type="      .. url_encode(media_type)
            .. "&uri="       .. url_encode(uri)
            .. "&timestamp=" .. url_encode(ts)
        os.execute('curl.exe -s --max-time 10 "' .. url .. '" > nul 2>&1')
    end

    update_nfo(uri)
end

function url_encode(str)
    if not str then return "" end
    str = tostring(str)
    str = str:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str:gsub(" ", "+")
end
