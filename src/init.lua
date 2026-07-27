-- =====================================================================
--  ⌥XL — Windows-style Alt shortcuts for Excel on Mac
--  Standalone engine (runs inside the rebranded ExcelAlt.app)
--  v11
--
--  v11 FIX: event taps run ONLY while Excel is frontmost (app watcher);
--  no frontmostApplication() query inside tap callbacks.
--  v12 FIX: tap callbacks are now PURE — they only mutate state and
--  return immediately. All UI (overlay canvas, alerts) is deferred to
--  the next runloop tick via hs.timer.doAfter(0, …). v11 still built
--  and showed the overlay window INSIDE the callback; window creation
--  while the window server is waiting on the tap can deadlock, so
--  macOS killed the tap (typing dead in Excel) and the engine's
--  re-enable restarted the cycle (shortcuts dead too).
--  v13: self-configuring launch (no installer needed), engine console/
--  prefs windows force-closed at startup, manager window no longer
--  pinned on top, clear-all/contents/formats built-ins, freeze panes
--  via locale-proof AppleScript instead of menu paths.
--  v14: packaging — release DMG built & properly signed by macOS CI.
--  v3.2: multi-host. Excel, PowerPoint and Word each get their own
--  shortcut set, their own slice of shortcuts.json, their own accent in
--  the manager, and their own on/off switch. Everything derives from the
--  APPS table below, so a fourth host is a row there plus a BUILTINS set.
--  shortcuts.json moved to schema v2 (per-host slices) and migrates v1
--  files on load; the Excel slice is still mirrored to the old top-level
--  keys so a rollback to v3.1 does not orphan the user's customs.
-- =====================================================================

-- Global state table FIRST (v8 crash fix: never index before init)
ExcelAlt = {
  version    = "dev",   -- replaced at startup by the bundle's real version
  enabled    = true,
  overlayOn  = true,   -- KeyTips panel; expert users can switch it off
  mode       = false,
  seq        = "",
  activeApp  = nil,    -- "excel"|"powerpoint"|"word"|nil — cached by the app
                       -- watcher; NEVER queried from inside a tap callback
  excelFront = false,  -- legacy mirror of (activeApp == "excel")
  appEnabled = { excel = true, powerpoint = true, word = true },
  tapsReady  = false,  -- true once Accessibility permission is granted
  bar        = nil,    -- menubar object held globally (GC fix)
  barIcon    = nil,
  overlay    = nil,
  manager    = nil,
  ucc        = nil,
  flagsTap   = nil,
  keyTap     = nil,
  watcher    = nil,
  optDown    = false,
  optAlone   = true,
  timeout    = nil,
  permTimer  = nil,
}

-- ---------------------------------------------------------------------
-- Supported hosts. Each entry owns its own shortcut set, its own slice of
-- shortcuts.json, and its own accent colour in the manager window.
--   bundle  — canonical bundle id (matched case-insensitively, see BY_BUNDLE)
--   as      — AppleScript application name
--   accent  — theme colour, used by the manager UI and the KeyTips overlay
-- ---------------------------------------------------------------------
local APPS = {
  { id = "excel", label = "Excel", bundle = "com.microsoft.Excel",
    as = "Microsoft Excel", noun = "cells",
    accent = "#0F6A3F", accent2 = "#1F8A55", accentDark = "#0C5733", tint = "#F5C542" },
  { id = "powerpoint", label = "PowerPoint", bundle = "com.microsoft.Powerpoint",
    as = "Microsoft PowerPoint", noun = "shapes",
    accent = "#C43E1C", accent2 = "#E2603C", accentDark = "#9E3116", tint = "#FFAE86" },
  { id = "word", label = "Word", bundle = "com.microsoft.Word",
    as = "Microsoft Word", noun = "text",
    accent = "#185ABD", accent2 = "#2B7CD3", accentDark = "#12489A", tint = "#8FC0FF" },
}
local APP = {}          -- id -> app record
local BY_BUNDLE = {}    -- lowercased bundle id -> app id
for _, a in ipairs(APPS) do
  APP[a.id] = a
  BY_BUNDLE[a.bundle:lower()] = a.id
end
-- PowerPoint has shipped under both "com.microsoft.Powerpoint" and
-- "...PowerPoint" depending on version; the lookup is lowercased so either
-- spelling resolves. Extra aliases go here.
BY_BUNDLE["com.microsoft.powerpoint"] = "powerpoint"

local EXCEL   = APP.excel.bundle   -- kept: referenced by startup diagnostics
local SELF_BUNDLE = (hs.processInfo and hs.processInfo.bundleID) or "com.corgianalyst.excel-alt-shortcuts"
local APPNAME = "⌥XL"
local SEQ_TIMEOUT = 4

-- ---------------------------------------------------------------------
-- Paths & persistence (own Application Support dir, never Hammerspoon's)
-- ---------------------------------------------------------------------
-- Single source of truth for the version: the app bundle's Info.plist,
-- which the build stamps from the release tag. Hardcoding it in source
-- made the About window and feedback emails disagree after every release.
do
  local ok, v = pcall(function()
    local plistPath = (hs.processInfo.bundlePath or "") .. "/Contents/Info.plist"
    local d = hs.plist and hs.plist.read and hs.plist.read(plistPath)
    return d and d.CFBundleShortVersionString
  end)
  if ok and type(v) == "string" and #v > 0 then ExcelAlt.version = v end
end

local FEEDBACK_TO   = "vito.continental@gmail.com"
local STATS_URL     = "https://raw.githubusercontent.com/continental-vito/xlalt/main/docs/feedback-stats.json"

local SUPPORT = os.getenv("HOME") .. "/Library/Application Support/ExcelAlt"
hs.fs.mkdir(SUPPORT)
local STORE = SUPPORT .. "/shortcuts.json"
local PREFS = SUPPORT .. "/prefs.json"

-- Lightweight diagnostics: ~/Library/Application Support/ExcelAlt/debug.log
local function dlog(msg)
  local f = io.open(SUPPORT .. "/debug.log", "a")
  if f then f:write(os.date("%Y-%m-%d %H:%M:%S  ") .. tostring(msg) .. "\n") ; f:close() end
end

local function fileExists(p)
  local a = hs.fs.attributes(p)
  return a ~= nil and a.mode == "file"
end

local function readJSON(p)
  if not fileExists(p) then return nil end            -- no first-run noise
  local f = io.open(p, "r"); if not f then return nil end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(hs.json.decode, raw)
  if ok then return data end
  return nil
end

local function writeJSON(p, tbl)
  local f = io.open(p, "w"); if not f then return false end
  f:write(hs.json.encode(tbl, true)); f:close()
  return true
end

-- ---------------------------------------------------------------------
-- Feedback
-- ---------------------------------------------------------------------
local function urlEncode(str)
  return (tostring(str):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Published stats (curated JSON in the repo) so the app can show a real
-- average without running a server. Cached locally after first fetch.
local FSTATS = SUPPORT .. "/feedback-stats.json"

local function localFeedback()
  return readJSON(SUPPORT .. "/feedback.json") or { sent = 0 }
end

local function pushStatsToUI()
  if not ExcelAlt.manager then return end
  local remote = readJSON(FSTATS) or {}
  local payload = {
    average = remote.average, ratings = remote.ratings, comments = remote.comments,
    sent = localFeedback().sent or 0,
  }
  ExcelAlt.manager:evaluateJavaScript("setStats(" .. hs.json.encode(payload) .. ")")
end

local function refreshStats()
  pcall(function()
    hs.http.asyncGet(STATS_URL, nil, function(code, body)
      if code == 200 and body and #body < 4096 then
        local ok, data = pcall(hs.json.decode, body)
        if ok and type(data) == "table" then
          writeJSON(FSTATS, data)
          pcall(pushStatsToUI)
        end
      end
    end)
  end)
end

local function sendFeedback(rating, comment, contact)
  local osver = ""
  pcall(function()
    local v = hs.host.operatingSystemVersion()
    osver = string.format("macOS %d.%d.%d", v.major or 0, v.minor or 0, v.patch or 0)
  end)
  local stars = string.rep("★", math.max(1, math.min(5, tonumber(rating) or 5)))
  local subject = string.format("[XL feedback] %s (%s/5)", stars, tostring(rating))
  local body = table.concat({
    "Rating: " .. tostring(rating) .. "/5",
    "",
    "Comment:",
    (comment ~= nil and #comment > 0) and comment or "(no comment)",
    "",
    "Reply to: " .. ((contact ~= nil and #contact > 0) and contact or "(not provided)"),
    "",
    "---",
    "XL version " .. ExcelAlt.version .. "  " .. osver,
  }, "\n")

  local url = string.format("mailto:%s?subject=%s&body=%s",
    FEEDBACK_TO, urlEncode(subject), urlEncode(body))
  hs.execute("open '" .. url .. "'")

  local f = localFeedback()
  f.sent = (f.sent or 0) + 1
  f.lastRating = rating
  writeJSON(SUPPORT .. "/feedback.json", f)
  dlog("feedback: composed mail, rating=" .. tostring(rating))
  return true
end

-- ---------------------------------------------------------------------
-- Host helpers. Every action is bound to the app whose shortcut set it
-- belongs to, so the same factory serves Excel, PowerPoint and Word.
-- All of these run OUTSIDE the tap callback (dispatched via doAfter).
-- ---------------------------------------------------------------------
local function hostApp(appId)
  return hs.application.get(APP[appId] and APP[appId].bundle or EXCEL)
end

local function stroke(appId, mods, key)
  return function()
    hs.eventtap.keyStroke(mods, key, 0, hostApp(appId))
  end
end

-- Click a menu path; if the item can't be found (localization, version
-- differences), run the AppleScript fallback instead.
local function menuThen(appId, path, fallbackFn)
  return function()
    local app = hostApp(appId); if not app then return end
    if app:selectMenuItem(path) then return end
    local pat = "^" .. path[#path]:gsub("%p", "%%%1")
    local p2 = {}
    for i = 1, #path - 1 do p2[i] = path[i] end
    p2[#path] = pat
    if app:selectMenuItem(p2, true) then return end
    dlog("menu path not found in " .. appId .. ": " .. table.concat(path, " > "))
    if fallbackFn then fallbackFn() end
  end
end

-- AppleScript failures are silent by design (the user just sees nothing
-- happen), which made broken actions impossible to diagnose from a bug
-- report. Every failure now names the host and the offending line in
-- debug.log, so one log settles which entries are wrong.
local function ascript(appId, body)
  local target = (APP[appId] and APP[appId].as) or "Microsoft Excel"
  return function()
    local ok, _, err = hs.osascript.applescript(
      'tell application "' .. target .. '"\n' .. body .. '\nend tell')
    if not ok then
      dlog("applescript FAILED [" .. appId .. "] " ..
           (body:match("[^\n]*") or "") .. "  -> " .. tostring(err))
    end
    return ok
  end
end

-- Excel-only shorthand: the built-ins below predate multi-app support and
-- read better without the id repeated on every line.
local function xl(body) return ascript("excel", body) end

local function border(edge, style, weight)
  style  = style  or "continuous"
  weight = weight or "border weight thin"
  return xl(string.format(
    'set b to (get border of selection which border %s)\nset line style of b to %s\nset weight of b to %s',
    edge, style, weight))
end

local function noBorders()
  return xl([[
repeat with e in {edge bottom, edge top, edge left, edge right, inside horizontal, inside vertical}
  set line style of (get border of selection which border (contents of e)) to line style none
end repeat]])
end

local function allBorders(edges, weight)
  weight = weight or "border weight thin"
  local lines = { "repeat with e in {" .. edges .. "}" ,
    "  set b to (get border of selection which border (contents of e))",
    "  set line style of b to continuous",
    "  set weight of b to " .. weight,
    "end repeat" }
  return xl(table.concat(lines, "\n"))
end

-- Decimal adjust heuristic (tested against #,##0.00 / $ / % / multi-section)
local function adjustFormat(fmt, delta)
  if fmt == "General" or fmt == "" then
    return delta > 0 and "0.0" or "0"
  end
  local out = {}
  for section in (fmt .. ";"):gmatch("([^;]*);") do
    local dot = section:find("%.")
    if delta > 0 then
      if dot then
        section = section:gsub("(%.0+)", function(z) return z .. "0" end, 1)
      else
        -- insert .0 after last digit token of the integer part
        local pos
        for i = #section, 1, -1 do
          local c = section:sub(i, i)
          if c == "0" or c == "#" then pos = i break end
        end
        if pos then
          section = section:sub(1, pos) .. ".0" .. section:sub(pos + 1)
        end
      end
    else
      if dot then
        local zeros = section:match("%.(0+)")
        if zeros and #zeros > 1 then
          section = section:gsub("%.(0+)", function(z) return "." .. z:sub(2) end, 1)
        elseif zeros then
          section = section:gsub("%.0", "", 1)
        end
      end
    end
    out[#out + 1] = section
  end
  return table.concat(out, ";")
end

local function decimals(delta)
  return function()
    local ok, fmt = hs.osascript.applescript(
      'tell application "Microsoft Excel" to get number format of selection')
    if not ok or type(fmt) ~= "string" then return end
    local newFmt = adjustFormat(fmt, delta):gsub('"', '\\"')
    hs.osascript.applescript(
      'tell application "Microsoft Excel" to set number format of selection to "' .. newFmt .. '"')
  end
end

local function setFormat(fmt)
  return xl('set number format of selection to "' .. fmt .. '"')
end

-- ---------------------------------------------------------------------
-- Built-in shortcut maps, one per host (declarative: every entry knows its
-- own command, so the manager can display and edit it).
--
-- PowerPoint and Word deliberately use KEYSTROKES wherever a native Mac
-- shortcut exists, and AppleScript otherwise. Menu paths are avoided in
-- built-ins: they must match the host's display language, which breaks on
-- any non-English macOS. Users can still create menu-path shortcuts of
-- their own from the manager, where they can see and fix them.
-- ---------------------------------------------------------------------
local BUILTINS = {}

BUILTINS.excel = {
  { seq = "hvv", desc = "Paste values",      kind = "applescript", script = "paste special selection what paste values" },
  { seq = "hvf", desc = "Paste formulas",    kind = "applescript", script = "paste special selection what paste formulas" },
  { seq = "hvt", desc = "Paste formats",     kind = "applescript", script = "paste special selection what paste formats" },
  { seq = "es",  desc = "Paste Special…",    kind = "keystroke",   mods = "ctrl+cmd", key = "v" },

  { seq = "h1",  desc = "Bold",              kind = "keystroke",   mods = "cmd", key = "b" },
  { seq = "h2",  desc = "Italic",            kind = "keystroke",   mods = "cmd", key = "i" },
  { seq = "h3",  desc = "Underline",         kind = "keystroke",   mods = "cmd", key = "u" },

  { seq = "hac", desc = "Align center",      kind = "applescript", script = "set horizontal alignment of selection to horizontal align center" },
  { seq = "hal", desc = "Align left",        kind = "applescript", script = "set horizontal alignment of selection to horizontal align left" },
  { seq = "har", desc = "Align right",       kind = "applescript", script = "set horizontal alignment of selection to horizontal align right" },
  { seq = "hat", desc = "Align top",         kind = "applescript", script = "set vertical alignment of selection to vertical alignment top" },
  { seq = "ham", desc = "Align middle",      kind = "applescript", script = "set vertical alignment of selection to vertical alignment center" },
  { seq = "hab", desc = "Align bottom",      kind = "applescript", script = "set vertical alignment of selection to vertical alignment bottom" },
  { seq = "hw",  desc = "Wrap text (toggle)",kind = "applescript", script = "set wrap text of selection to not (wrap text of selection)" },
  { seq = "hmc", desc = "Merge & center",    kind = "applescript", script = "merge selection\nset horizontal alignment of selection to horizontal align center" },
  { seq = "hmu", desc = "Unmerge cells",     kind = "applescript", script = "unmerge selection" },

  { seq = "h0",  desc = "Increase decimals", kind = "lua", fn = decimals(1),  cmd = "Smart decimal +1 on current number format" },
  { seq = "h9",  desc = "Decrease decimals", kind = "lua", fn = decimals(-1), cmd = "Smart decimal −1 on current number format" },
  { seq = "hp",  desc = "Percent style",     kind = "applescript", script = 'set number format of selection to "0%"' },
  { seq = "hk",  desc = "Comma style",       kind = "applescript", script = 'set number format of selection to "#,##0.00"' },
  { seq = "han", desc = "Accounting format", kind = "applescript", script = 'set number format of selection to "_($* #,##0.00_);_($* (#,##0.00);_($* \\"-\\"??_);_(@_)"' },

  { seq = "hbo", desc = "Bottom border",     kind = "lua", fn = border("edge bottom"),  cmd = "Border: bottom edge, thin" },
  { seq = "hbp", desc = "Top border",        kind = "lua", fn = border("edge top"),     cmd = "Border: top edge, thin" },
  { seq = "hbl", desc = "Left border",       kind = "lua", fn = border("edge left"),    cmd = "Border: left edge, thin" },
  { seq = "hbr", desc = "Right border",      kind = "lua", fn = border("edge right"),   cmd = "Border: right edge, thin" },
  { seq = "hbn", desc = "No borders",        kind = "lua", fn = noBorders(),            cmd = "Border: remove all edges" },
  { seq = "hba", desc = "All borders",       kind = "lua", fn = allBorders("edge bottom, edge top, edge left, edge right, inside horizontal, inside vertical"), cmd = "Border: all edges + inside, thin" },
  { seq = "hbs", desc = "Outside borders",   kind = "lua", fn = allBorders("edge bottom, edge top, edge left, edge right"), cmd = "Border: outside edges, thin" },
  { seq = "hbt", desc = "Thick box border",  kind = "lua", fn = allBorders("edge bottom, edge top, edge left, edge right", "border weight thick"), cmd = "Border: outside edges, thick" },

  { seq = "hoi", desc = "AutoFit column width", kind = "applescript", script = "autofit entire column of selection" },
  { seq = "hoa", desc = "AutoFit row height",   kind = "applescript", script = "autofit entire row of selection" },
  { seq = "how", desc = "Column width…",        kind = "menu", path = "Format > Column > Width..." },
  { seq = "hoh", desc = "Row height…",          kind = "menu", path = "Format > Row > Height..." },
  { seq = "hir", desc = "Insert row",           kind = "applescript", script = "insert into range (entire row of selection) shift shift down" },
  { seq = "hic", desc = "Insert column",        kind = "applescript", script = "insert into range (entire column of selection) shift shift to right" },
  { seq = "hdr", desc = "Delete row",           kind = "applescript", script = "delete range (entire row of selection) shift shift up" },
  { seq = "hdc", desc = "Delete column",        kind = "applescript", script = "delete range (entire column of selection) shift shift to left" },
  { seq = "hea", desc = "Clear all",            kind = "menu", path = "Edit > Clear > All",      fallback = "clear contents selection\nclear formats selection" },
  { seq = "hec", desc = "Clear contents",       kind = "menu", path = "Edit > Clear > Contents", fallback = "clear contents selection" },
  { seq = "hef", desc = "Clear formats",        kind = "menu", path = "Edit > Clear > Formats",  fallback = "clear formats selection" },

  { seq = "=",   desc = "AutoSum",              kind = "keystroke", mods = "cmd+shift", key = "t" },

  { seq = "asa", desc = "Sort ascending",       kind = "applescript", script = "sort selection key1 active cell order1 sort ascending" },
  { seq = "asd", desc = "Sort descending",      kind = "applescript", script = "sort selection key1 active cell order1 sort descending" },
  { seq = "att", desc = "Toggle AutoFilter",    kind = "applescript", script = "set autofilter mode of active sheet to not (autofilter mode of active sheet)" },
  { seq = "agg", desc = "Group rows/columns",   kind = "applescript", script = "group entire row of selection" },
  { seq = "agu", desc = "Ungroup",              kind = "applescript", script = "ungroup entire row of selection" },

  { seq = "wvg", desc = "Toggle gridlines",     kind = "applescript", script = "set display gridlines of active window to not (display gridlines of active window)" },
  { seq = "wff", desc = "Freeze panes (toggle)",kind = "applescript", script = "set freeze panes of active window to not (freeze panes of active window)" },
  { seq = "wfu", desc = "Unfreeze panes",       kind = "applescript", script = "set freeze panes of active window to false" },
}

BUILTINS.powerpoint = {
  -- Home: text
  { seq = "h1",  desc = "Bold",                 kind = "keystroke", mods = "cmd", key = "b" },
  { seq = "h2",  desc = "Italic",               kind = "keystroke", mods = "cmd", key = "i" },
  { seq = "h3",  desc = "Underline",            kind = "keystroke", mods = "cmd", key = "u" },
  { seq = "h4",  desc = "Strikethrough",        kind = "keystroke", mods = "cmd+shift", key = "x" },
  { seq = "hal", desc = "Align left",           kind = "keystroke", mods = "cmd", key = "l" },
  { seq = "hac", desc = "Align center",         kind = "keystroke", mods = "cmd", key = "e" },
  { seq = "har", desc = "Align right",          kind = "keystroke", mods = "cmd", key = "r" },
  { seq = "haj", desc = "Justify",              kind = "keystroke", mods = "cmd", key = "j" },
  { seq = "hfg", desc = "Grow font",            kind = "keystroke", mods = "cmd+shift", key = "." },
  { seq = "hfk", desc = "Shrink font",          kind = "keystroke", mods = "cmd+shift", key = "," },

  -- Home: slides
  { seq = "hi",  desc = "New slide",            kind = "keystroke", mods = "cmd+shift", key = "n" },
  { seq = "hd",  desc = "Duplicate",            kind = "keystroke", mods = "cmd+shift", key = "d" },

  -- Home: arrange
  { seq = "hg",  desc = "Group",                kind = "keystroke", mods = "cmd+alt", key = "g" },
  { seq = "hu",  desc = "Ungroup",              kind = "keystroke", mods = "cmd+alt+shift", key = "g" },
  { seq = "haf", desc = "Bring to front",       kind = "keystroke", mods = "cmd+shift", key = "f" },
  { seq = "hak", desc = "Send to back",         kind = "keystroke", mods = "cmd+shift", key = "b" },

  -- Home: editing
  { seq = "hc",  desc = "Copy formatting",      kind = "keystroke", mods = "cmd+shift", key = "c" },
  { seq = "hv",  desc = "Paste formatting",     kind = "keystroke", mods = "cmd+shift", key = "v" },
  { seq = "hfd", desc = "Find",                 kind = "keystroke", mods = "cmd", key = "f" },
  { seq = "he",  desc = "Replace",              kind = "keystroke", mods = "cmd+shift", key = "h" },

  -- Insert
  { seq = "nk",  desc = "Hyperlink",            kind = "keystroke", mods = "cmd", key = "k" },

  -- Slide Show
  { seq = "sb",  desc = "Play from beginning",  kind = "keystroke", mods = "cmd+shift", key = "return" },
  { seq = "sc",  desc = "Play from this slide", kind = "keystroke", mods = "cmd", key = "return" },

  -- View
  { seq = "wn",  desc = "Normal view",          kind = "keystroke", mods = "cmd", key = "1" },
  { seq = "ws",  desc = "Slide sorter",         kind = "keystroke", mods = "cmd", key = "2" },
  { seq = "wt",  desc = "Notes page",           kind = "keystroke", mods = "cmd", key = "3" },
}

BUILTINS.word = {
  -- Home: font
  { seq = "h1",  desc = "Bold",                 kind = "keystroke", mods = "cmd", key = "b" },
  { seq = "h2",  desc = "Italic",               kind = "keystroke", mods = "cmd", key = "i" },
  { seq = "h3",  desc = "Underline",            kind = "keystroke", mods = "cmd", key = "u" },
  { seq = "h4",  desc = "Strikethrough",        kind = "applescript",
    script = "set strike through of font object of selection to not (strike through of font object of selection)" },
  { seq = "hfg", desc = "Grow font",            kind = "applescript",
    script = "set font size of font object of selection to ((font size of font object of selection) + 1)" },
  { seq = "hfk", desc = "Shrink font",          kind = "applescript",
    script = "set font size of font object of selection to ((font size of font object of selection) - 1)" },
  { seq = "hx",  desc = "Superscript",          kind = "applescript",
    script = "set superscript of font object of selection to not (superscript of font object of selection)" },
  { seq = "hb",  desc = "Subscript",            kind = "applescript",
    script = "set subscript of font object of selection to not (subscript of font object of selection)" },
  { seq = "huc", desc = "All caps",             kind = "applescript",
    script = "set all caps of font object of selection to not (all caps of font object of selection)" },

  -- Home: paragraph
  { seq = "hal", desc = "Align left",           kind = "keystroke", mods = "cmd", key = "l" },
  { seq = "hac", desc = "Align center",         kind = "keystroke", mods = "cmd", key = "e" },
  { seq = "har", desc = "Align right",          kind = "keystroke", mods = "cmd", key = "r" },
  { seq = "haj", desc = "Justify",              kind = "keystroke", mods = "cmd", key = "j" },

  -- Home: styles
  { seq = "hs1", desc = "Heading 1",            kind = "keystroke", mods = "cmd+alt", key = "1" },
  { seq = "hs2", desc = "Heading 2",            kind = "keystroke", mods = "cmd+alt", key = "2" },
  { seq = "hs3", desc = "Heading 3",            kind = "keystroke", mods = "cmd+alt", key = "3" },
  { seq = "hsn", desc = "Normal style",         kind = "keystroke", mods = "cmd+shift", key = "n" },

  -- Home: editing & clipboard
  { seq = "hvv", desc = "Paste text only",      kind = "keystroke", mods = "cmd+alt+shift", key = "v" },
  { seq = "hc",  desc = "Copy formatting",      kind = "keystroke", mods = "cmd+shift", key = "c" },
  { seq = "hv",  desc = "Paste formatting",     kind = "keystroke", mods = "cmd+shift", key = "v" },
  { seq = "hfd", desc = "Find",                 kind = "keystroke", mods = "cmd", key = "f" },
  { seq = "he",  desc = "Replace",              kind = "keystroke", mods = "cmd+shift", key = "h" },

  -- Insert
  { seq = "nk",  desc = "Hyperlink",            kind = "keystroke", mods = "cmd", key = "k" },
  { seq = "nb",  desc = "Page break",           kind = "keystroke", mods = "cmd", key = "return" },
  { seq = "nf",  desc = "Footnote",             kind = "keystroke", mods = "cmd+alt", key = "f" },

  -- Review
  { seq = "rc",  desc = "New comment",          kind = "keystroke", mods = "cmd+alt", key = "a" },
  { seq = "rt",  desc = "Track changes",        kind = "keystroke", mods = "cmd+shift", key = "e" },
  { seq = "rw",  desc = "Word count",           kind = "applescript",
    script = "get count of words of active document" },

  -- View
  { seq = "wp",  desc = "Print layout view",    kind = "keystroke", mods = "cmd+alt", key = "p" },
  { seq = "wo",  desc = "Outline view",         kind = "keystroke", mods = "cmd+alt", key = "o" },
  { seq = "wd",  desc = "Draft view",           kind = "keystroke", mods = "cmd+alt", key = "n" },
}

-- ---------------------------------------------------------------------
-- Custom shortcuts + disabled built-ins (manager persistence)
--
-- Schema v2 keys everything under `apps`, one slice per host. v1 files were
-- flat (custom/disabled/renames at the top level) and Excel-only, so they
-- migrate into apps.excel on load.
--
-- saveStore() ALSO mirrors the Excel slice back to the top level. That is
-- deliberate: it keeps the file readable by v3.1 and earlier, so rolling
-- the app back does not silently orphan the user's Excel customs.
-- ---------------------------------------------------------------------
local function blankSlice() return { custom = {}, disabled = {}, renames = {} } end

local store = readJSON(STORE) or {}
local migrated = false
if type(store.apps) ~= "table" then
  local legacy = {
    custom   = type(store.custom) == "table" and store.custom or {},
    disabled = type(store.disabled) == "table" and store.disabled or {},
    renames  = type(store.renames) == "table" and store.renames or {},
  }
  migrated = (#legacy.custom > 0) or (next(legacy.disabled) ~= nil) or (next(legacy.renames) ~= nil)
  store.apps = { excel = legacy }
end
for _, a in ipairs(APPS) do
  local slice = store.apps[a.id]
  if type(slice) ~= "table" then slice = blankSlice() end
  slice.custom   = type(slice.custom) == "table" and slice.custom or {}
  slice.disabled = type(slice.disabled) == "table" and slice.disabled or {}
  slice.renames  = type(slice.renames) == "table" and slice.renames or {}
  store.apps[a.id] = slice
end
store.version = 2
if migrated then
  dlog("store: migrated v1 (Excel-only) shortcuts.json to v2 multi-app schema")
end

local function slice(appId) return store.apps[appId] or store.apps.excel end

local function parseMods(str)
  local mods = {}
  for m in (str or ""):gmatch("[^+]+") do mods[#mods + 1] = m end
  return mods
end

local function parsePath(str)
  local path = {}
  for part in (str or ""):gmatch("[^>]+") do
    path[#path + 1] = part:match("^%s*(.-)%s*$")
  end
  return path
end

-- One factory for built-ins AND customs: entry -> executable function,
-- bound to the host whose shortcut set the entry belongs to.
local function fnFor(e, appId)
  if e.kind == "lua" then
    return e.fn
  elseif e.kind == "keystroke" then
    return stroke(appId, parseMods(e.mods), e.key or "")
  elseif e.kind == "menu" then
    return menuThen(appId, parsePath(e.path), e.fallback and ascript(appId, e.fallback) or nil)
  else
    return ascript(appId, e.script or "")
  end
end

local PRETTY = { cmd = "⌘", shift = "⇧", ctrl = "⌃", alt = "⌥", fn = "fn" }
local function cmdFor(e)
  if e.kind == "lua" then return e.cmd or "Built-in action" end
  if e.kind == "keystroke" then
    local out = ""
    for _, m in ipairs(parseMods(e.mods)) do out = out .. (PRETTY[m] or m) end
    return "Keys: " .. out .. (e.key or ""):upper()
  end
  if e.kind == "menu" then return "Menu: " .. (e.path or "") end
  local first = (e.script or ""):match("[^\n]*") or ""
  if #first > 46 then first = first:sub(1, 43) .. "…" end
  return "Script: " .. first
end

local function paramFor(e)
  if e.kind == "keystroke" then
    local m = e.mods or ""
    return (#m > 0 and (m .. "+") or "") .. (e.key or "")
  elseif e.kind == "menu" then return e.path or ""
  elseif e.kind == "applescript" then return e.script or ""
  end
  return ""
end

-- Lookup tables, one set per host. Indexed inside the tap callback, so
-- these are plain tables: rebuilding replaces their contents, never blocks.
local EXACT, PREFIX, CATALOG = {}, {}, {}

local function rebuildApp(appId)
  local exact, prefixes, catalog = {}, {}, {}
  local sl = slice(appId)
  local function add(seq, desc, fn, builtin, meta)
    exact[seq] = { desc = desc, fn = fn }
    for i = 1, #seq - 1 do prefixes[seq:sub(1, i)] = true end
    local row = { seq = seq, desc = desc, builtin = builtin }
    for k, v in pairs(meta or {}) do row[k] = v end
    catalog[#catalog + 1] = row
  end
  for _, b in ipairs(BUILTINS[appId] or {}) do
    if not sl.disabled[b.seq] then
      local r = sl.renames[b.seq] or {}
      local seq  = (r.seq and #r.seq > 0) and r.seq:lower() or b.seq
      local desc = (r.desc and #r.desc > 0) and r.desc or b.desc
      add(seq, desc, fnFor(b, appId), true, {
        orig = b.seq, kind = b.kind, luaKind = (b.kind == "lua"),
        cmd = cmdFor(b), param = paramFor(b) })
    end
  end
  for _, c in ipairs(sl.custom) do
    if c.seq and #c.seq > 0 then
      add(c.seq:lower(), c.desc or "Custom", fnFor(c, appId), false, {
        orig = c.seq, kind = c.kind, luaKind = false,
        cmd = cmdFor(c), param = paramFor(c) })
    end
  end
  table.sort(catalog, function(a, b) return a.seq < b.seq end)
  EXACT[appId], PREFIX[appId], CATALOG[appId] = exact, prefixes, catalog
end

local function rebuild()
  for _, a in ipairs(APPS) do rebuildApp(a.id) end
end
rebuild()

-- ---------------------------------------------------------------------
-- KeyTips overlay (canvas panel, filters as you type)
-- ---------------------------------------------------------------------
local function overlayHide()
  if ExcelAlt.overlay then ExcelAlt.overlay:delete() ; ExcelAlt.overlay = nil end
end

local function overlayShow()
  overlayHide()
  if not ExcelAlt.overlayOn then return end
  local appId = ExcelAlt.activeApp
  local host = APP[appId]
  if not host then return end
  local hints = {}
  for _, item in ipairs(CATALOG[appId] or {}) do
    if item.seq:sub(1, #ExcelAlt.seq) == ExcelAlt.seq then
      hints[#hints + 1] = item
      if #hints == 9 then break end
    end
  end
  local rows = math.max(#hints, 1)
  local W, RH, PAD = 340, 24, 14
  local H = PAD * 2 + 30 + rows * RH
  local scr = hs.screen.mainScreen():frame()
  local c = hs.canvas.new({
    x = scr.x + (scr.w - W) / 2,
    y = scr.y + scr.h - H - 60,
    w = W, h = H })
  c:appendElements({
    type = "rectangle", action = "fill",
    roundedRectRadii = { xRadius = 12, yRadius = 12 },
    fillColor = { red = 0.09, green = 0.10, blue = 0.11, alpha = 0.94 } })
  c:appendElements({
    type = "text",
    text = "⌥  " .. ExcelAlt.seq:upper() .. "▮",
    textSize = 17, textColor = { hex = host.tint },
    frame = { x = PAD, y = PAD - 2, w = W - PAD * 2 - 90, h = 26 } })
  -- Which host's set is active: the same letters mean different things in
  -- Excel and Word, so the panel always says which one it is driving.
  c:appendElements({
    type = "text", text = host.label,
    textSize = 11, textColor = { hex = "#7E8A84" }, textAlignment = "right",
    frame = { x = W - PAD - 90, y = PAD + 3, w = 90, h = 18 } })
  if #hints == 0 then
    c:appendElements({ type = "text", text = "no match — Esc to cancel",
      textSize = 13, textColor = { hex = "#999999" },
      frame = { x = PAD, y = PAD + 26, w = W - PAD * 2, h = RH } })
  end
  for i, h in ipairs(hints) do
    local rest = h.seq:sub(#ExcelAlt.seq + 1):upper()
    c:appendElements({ type = "text",
      text = rest, textSize = 14,
      textColor = { hex = "#FFFFFF" },
      frame = { x = PAD, y = PAD + 24 + (i - 1) * RH, w = 60, h = RH } })
    c:appendElements({ type = "text",
      text = h.desc, textSize = 13,
      textColor = { hex = "#B7C4BD" },
      frame = { x = PAD + 64, y = PAD + 25 + (i - 1) * RH, w = W - PAD * 2 - 64, h = RH } })
  end
  c:level(hs.canvas.windowLevels.overlay)
  c:show()
  ExcelAlt.overlay = c
end

-- ---------------------------------------------------------------------
-- Deferred UI: tap callbacks must NEVER touch the window server.
-- scheduleUI() coalesces overlay updates onto the next runloop tick;
-- say() defers alerts the same way.
-- ---------------------------------------------------------------------
local uiScheduled = false
local function scheduleUI()
  if uiScheduled then return end
  uiScheduled = true
  hs.timer.doAfter(0, function()
    uiScheduled = false
    if ExcelAlt.mode then overlayShow() else overlayHide() end
  end)
end

local function say(msg, dur)
  hs.timer.doAfter(0, function() hs.alert.show(msg, dur) end)
end

-- ---------------------------------------------------------------------
-- Sequence mode
-- ---------------------------------------------------------------------
local function exitMode()
  ExcelAlt.mode, ExcelAlt.seq = false, ""
  scheduleUI()
  if ExcelAlt.timeout then ExcelAlt.timeout:stop() ; ExcelAlt.timeout = nil end
end

local function enterMode()
  ExcelAlt.mode, ExcelAlt.seq = true, ""
  scheduleUI()
  if ExcelAlt.timeout then ExcelAlt.timeout:stop() end
  ExcelAlt.timeout = hs.timer.doAfter(SEQ_TIMEOUT, exitMode)
end

-- NOTE: these handlers run while macOS is holding keyboard delivery for
-- the whole system. They must be fast, allocation-light, and must never
-- make blocking calls: no frontmostApplication, no AppleScript, no I/O,
-- and NO UI — no canvas, no alerts, no window-server calls of any kind.
-- State only; everything visible happens via scheduleUI()/say().
local function handleFlags(e)
  if not ExcelAlt.enabled or not ExcelAlt.activeApp then return false end
  local alt = e:getFlags().alt
  if alt and not ExcelAlt.optDown then
    ExcelAlt.optDown, ExcelAlt.optAlone = true, true
  elseif not alt and ExcelAlt.optDown then
    ExcelAlt.optDown = false
    if ExcelAlt.optAlone then
      if ExcelAlt.mode then exitMode() else enterMode() end
    end
  end
  return false
end

local function handleKey(e)
  local appId = ExcelAlt.activeApp
  if not ExcelAlt.enabled or not appId then
    if ExcelAlt.mode then exitMode() end
    return false
  end
  if ExcelAlt.optDown then ExcelAlt.optAlone = false ; return false end
  if not ExcelAlt.mode then return false end

  -- Digits by PHYSICAL key position: on AZERTY (and other layouts) the
  -- unshifted digit row types symbols (& é " …), so layout-based lookup
  -- would never produce "1".."0". Raw keycodes are layout-independent.
  local DIGITS = { [18]="1",[19]="2",[20]="3",[21]="4",[23]="5",
                   [22]="6",[26]="7",[28]="8",[25]="9",[29]="0" }
  local key = DIGITS[e:getKeyCode()] or hs.keycodes.map[e:getKeyCode()]
  if key == "escape" then exitMode() ; return true end
  if type(key) ~= "string" or #key ~= 1 then exitMode() ; return false end

  ExcelAlt.seq = ExcelAlt.seq .. key:lower()
  if ExcelAlt.timeout then ExcelAlt.timeout:stop() end
  ExcelAlt.timeout = hs.timer.doAfter(SEQ_TIMEOUT, exitMode)

  local hit = (EXACT[appId] or {})[ExcelAlt.seq]
  if hit then
    exitMode()
    if ExcelAlt.overlayOn then say(hit.desc, 0.8) end   -- expert mode: silent success
    hs.timer.doAfter(0.05, hit.fn)   -- action runs OUTSIDE the tap callback
    return true
  elseif (PREFIX[appId] or {})[ExcelAlt.seq] then
    scheduleUI()
    return true
  else
    local bad = ExcelAlt.seq:upper()
    exitMode()
    say("No shortcut:  ⌥ " .. bad, 1)
    return true
  end
end

-- An error inside a tap callback would stall key delivery system-wide:
-- guarantee we always return promptly, passing the event through.
local function safely(fn)
  return function(e)
    local ok, swallow = pcall(fn, e)
    if ok then return swallow end
    return false
  end
end

-- ---------------------------------------------------------------------
-- Tap lifecycle: taps exist once, run ONLY when Excel is frontmost,
-- permission is granted, and shortcuts are enabled.
-- ---------------------------------------------------------------------
local function updateTaps()
  local appId = ExcelAlt.activeApp
  local want = ExcelAlt.tapsReady and appId ~= nil and ExcelAlt.enabled
                 and ExcelAlt.appEnabled[appId] ~= false
  if want then
    if not ExcelAlt.flagsTap:isEnabled() then ExcelAlt.flagsTap:start() end
    if not ExcelAlt.keyTap:isEnabled()   then ExcelAlt.keyTap:start()   end
  else
    if ExcelAlt.flagsTap:isEnabled() then ExcelAlt.flagsTap:stop() end
    if ExcelAlt.keyTap:isEnabled()   then ExcelAlt.keyTap:stop()   end
    ExcelAlt.optDown = false
    exitMode()
  end
end

local function onAppEvent(_, event, app)
  local w = hs.application.watcher
  if event ~= w.activated and event ~= w.deactivated and event ~= w.terminated then
    return
  end
  local bid = app ~= nil and app:bundleID() or nil
  -- Cmd+Q quits ExcelAlt, but only while ExcelAlt itself is frontmost
  if bid == SELF_BUNDLE and ExcelAlt.quitKey then
    if event == w.activated then
      pcall(function() ExcelAlt.quitKey:enable() end)
    else
      pcall(function() ExcelAlt.quitKey:disable() end)
    end
  end
  local hostId = bid and BY_BUNDLE[bid:lower()] or nil
  if event == w.activated then
    ExcelAlt.activeApp = hostId
  elseif hostId then           -- a supported host deactivated or quit
    ExcelAlt.activeApp = nil
  else
    return                     -- some other app went away: nothing changes
  end
  ExcelAlt.excelFront = (ExcelAlt.activeApp == "excel")   -- legacy mirror
  updateTaps()
end

-- ---------------------------------------------------------------------
-- Shortcut Manager window
-- ---------------------------------------------------------------------
local MANAGER_HTML = [==[
<!doctype html><html><head><meta charset="utf-8"><style>
:root { --accent:#0F6A3F; --accent2:#1F8A55; --accentDark:#0C5733;
        --gold:#F5C542; --ink:#1c211e; --paper:#F7F5EF; }
* { box-sizing:border-box; margin:0; font-family:-apple-system,'SF Pro Text',Helvetica,sans-serif; }
body { background:var(--paper); color:var(--ink); padding:0 0 40px; }
header { background:linear-gradient(180deg,var(--accent2),var(--accent)); color:#fff;
  padding:16px 24px; display:flex; align-items:center; gap:14px; transition:background .18s; }
header img { width:44px; height:44px; border-radius:10px; }
header h1 { font-size:19px; font-weight:700; }
header p { font-size:12px; opacity:.85; margin-top:2px; }
main { padding:18px 24px; max-width:860px; margin:0 auto; }
table { width:100%; border-collapse:collapse; background:#fff; border-radius:10px; overflow:hidden;
  box-shadow:0 1px 4px rgba(0,0,0,.08); }
th { text-align:left; font-size:11px; text-transform:uppercase; letter-spacing:.8px;
  color:#6b7570; padding:10px 12px; border-bottom:1px solid #e6e3da; }
td { padding:8px 12px; font-size:13px; border-bottom:1px solid #f0ede5; vertical-align:middle; }
td.seq { font-family:'SF Mono',Menlo,monospace; font-weight:700; color:var(--accent); white-space:nowrap; }
td.seq::before { content:'⌥ '; color:var(--gold); }
td.cmd { font-size:11.5px; color:#6b7570; max-width:260px; overflow:hidden;
  text-overflow:ellipsis; white-space:nowrap; }
tr:hover td { background:#fbfaf6; }
.tag { font-size:10px; padding:2px 7px; border-radius:99px; background:#eef3ee; color:#4c6355; }
.tag.custom { background:#fdf3d5; color:#8a6a12; }
button { border:0; border-radius:7px; padding:6px 11px; font-size:12px; cursor:pointer; }
button.edit { background:transparent; color:var(--accent); font-weight:600; }
button.edit:hover { background:rgba(0,0,0,.05); }
button.del { background:transparent; color:#b04a3a; }
button.del:hover { background:#f9e9e6; }
.addbar { display:flex; gap:8px; margin:16px 0 6px; flex-wrap:wrap; align-items:center; }
.addbar input, .addbar select { padding:8px 10px; border:1px solid #d8d4c8; border-radius:7px;
  font-size:13px; background:#fff; }
.addbar .sq { width:76px; font-family:'SF Mono',Menlo,monospace; }
.addbar .ds { flex:1; min-width:130px; }
.addbar .pm { flex:2; min-width:190px; }
.addbar .go { background:var(--accent); color:#fff; font-weight:600; }
.addbar .go:hover { background:var(--accent2); }
.addbar .cancel { background:transparent; color:#6b7570; display:none; }
.err { display:none; color:#b04a3a; font-size:12px; margin:2px 0 6px; font-weight:600; }
.guide { background:#fff; border:1px solid #e6e3da; border-radius:10px; padding:10px 14px; margin-bottom:12px; }
.guide summary { font-size:12.5px; font-weight:700; color:var(--accent); cursor:pointer; }
.guide .g p { font-size:12px; color:#4a4f4b; margin:9px 0 0; line-height:1.55; }
.guide code { background:#f2efe7; border-radius:4px; padding:1px 5px; font-family:'SF Mono',Menlo,monospace; font-size:11px; }
.guide .gnote { color:#8a877d; font-size:11.5px; }
.toggle { display:flex; align-items:center; justify-content:space-between; gap:14px; background:#fff;
  border:1px solid #e6e3da; border-radius:10px; padding:11px 14px; margin-top:14px; }
.toggle .sw { display:flex; align-items:center; gap:9px; font-size:13px; font-weight:600; cursor:pointer; }
.toggle .sw input { width:17px; height:17px; accent-color:var(--accent); cursor:pointer; }
.toggle .note { font-size:11.5px; color:#8a877d; margin:3px 0 0 26px; }
nav.tabs { display:flex; gap:4px; padding:0 24px; background:linear-gradient(180deg,var(--accent),var(--accentDark));
  transition:background .18s; }
nav.tabs button { background:transparent; color:rgba(255,255,255,.72); font-size:13px; font-weight:600;
  padding:9px 16px; border-radius:8px 8px 0 0; }
nav.tabs button:hover { color:#fff; }
nav.tabs button.on { background:var(--paper); color:var(--accent); }
.page { display:none; } .page.on { display:block; }
.off { display:none; background:#fff6e5; border:1px solid #f0dcae; color:#7a5b12; border-radius:9px;
  padding:9px 13px; font-size:12.5px; margin-top:14px; }
.fbwrap { max-width:560px; margin:24px auto 0; background:#fff; border:1px solid #e6e3da;
  border-radius:12px; padding:22px 24px; box-shadow:0 1px 4px rgba(0,0,0,.06); }
.fbwrap h2 { font-size:17px; margin-bottom:4px; }
.fbwrap .sub { font-size:12.5px; color:#7d8580; margin-bottom:18px; }
.stars { display:flex; gap:6px; margin:0 0 16px; }
.stars span { font-size:30px; line-height:1; cursor:pointer; color:#d9d5c9; transition:color .1s; }
.stars span.lit { color:var(--gold); }
.fbwrap textarea { width:100%; min-height:110px; padding:11px 12px; border:1px solid #d8d4c8;
  border-radius:9px; font-size:13px; font-family:inherit; resize:vertical; }
.fbwrap input.contact { width:100%; padding:10px 12px; margin-top:10px; border:1px solid #d8d4c8;
  border-radius:9px; font-size:13px; }
.fbwrap .send { background:var(--accent); color:#fff; font-weight:700; padding:10px 20px;
  font-size:13px; margin-top:14px; }
.fbwrap .send:hover { background:var(--accent2); }
.fbwrap .privacy { font-size:11.5px; color:#8a877d; margin-top:12px; line-height:1.5; }
.fbdone { display:none; background:#e9f2ec; border:1px solid #cfe3d7; color:#20603f;
  border-radius:9px; padding:11px 13px; font-size:12.5px; margin-top:14px; }
.statsbar { display:flex; align-items:center; justify-content:center; gap:22px; margin:18px auto 0;
  max-width:560px; color:#4a4f4b; font-size:13px; }
.statsbar .big { font-size:26px; font-weight:700; color:var(--accent); }
.statsbar .lbl { font-size:11px; color:#8a877d; text-transform:uppercase; letter-spacing:.7px; }
.statsbar div { text-align:center; }
.fblink { text-align:center; margin:22px 0 0; font-size:12.5px; color:#7d8580; }
.fblink a { color:var(--accent); font-weight:600; cursor:pointer; text-decoration:none; }
.search { flex:1; max-width:360px; padding:9px 12px; border:1px solid #d8d4c8; border-radius:8px;
  font-size:13px; background:#fbfaf6; }
.search:focus { outline:2px solid var(--accent2); background:#fff; }
#ax { display:none; background:#B04A3A; color:#fff; padding:10px 24px; font-size:13px;
  align-items:center; gap:12px; }
#ax button { background:#fff; color:#B04A3A; font-weight:700; }
</style></head><body>
<header>
  <img src="CORGI_SRC" alt="">
  <div><h1>⌥XL Shortcut Manager</h1>
    <p id="sub">Tap ⌥ in Excel, then type a sequence. Changes apply instantly.</p></div>
</header>
<div id="ax">
  <span style="flex:1">Shortcuts are OFF — macOS Accessibility permission is missing.</span>
  <button onclick="send({op:'axsettings'})">Open Accessibility Settings</button>
</div>
<nav class="tabs" id="tabs"></nav>
<div id="pages"></div>

<main id="page-fb" class="page">
  <div class="statsbar" id="statsbar" style="display:none">
    <div><div class="big" id="st-avg">–</div><div class="lbl">average rating</div></div>
    <div><div class="big" id="st-n">–</div><div class="lbl">ratings</div></div>
    <div><div class="big" id="st-c">–</div><div class="lbl">comments</div></div>
  </div>
  <div class="fbwrap">
    <h2>How is XL working for you?</h2>
    <p class="sub">Bug reports, missing shortcuts, and ideas all welcome.</p>
    <div class="stars" id="stars">
      <span data-v="1">★</span><span data-v="2">★</span><span data-v="3">★</span>
      <span data-v="4">★</span><span data-v="5">★</span>
    </div>
    <textarea id="fb-text" placeholder="What works, what doesn't, what's missing?"></textarea>
    <input class="contact" id="fb-contact" placeholder="Your email (optional — only if you'd like a reply)">
    <button class="send" onclick="sendFeedback()">Send feedback</button>
    <div class="fbdone" id="fb-done">Thanks! Your mail app should be open with the message ready — press send there to deliver it.</div>
    <p class="privacy">Your comment is emailed privately and is never shown to other users. Only the average rating and the number of ratings appear here.</p>
  </div>
</main>
<script>
const state = {};       // appId -> { all, items, editing }
let apps = [];          // host records pushed by the engine
let current = null;     // 'excel' | 'powerpoint' | 'word' | 'fb'

function esc(t) { const d = document.createElement('div'); d.textContent = t == null ? '' : t; return d.innerHTML; }
function $(id) { return document.getElementById(id); }
function send(msg) { window.webkit.messageHandlers.xl.postMessage(msg); }

// ---------------------------------------------------------------- guides
// The three hosts differ enough that one guide would be wrong for two of
// them: AppleScript vocabularies are unrelated, and PowerPoint's is thin.
function guideFor(a) {
  const common =
    '<p><b>1 · Keystroke</b> — replays a key combo ' + esc(a.label) + ' already understands. ' +
    'Write modifiers + key joined by <code>+</code>: <code>cmd+shift+t</code>, <code>cmd+alt+1</code>, <code>cmd+b</code>. ' +
    'Best when there is a native Mac shortcut and you just want it behind an ⌥ sequence.</p>' +
    '<p><b>2 · Menu path</b> — clicks an item in the <i>menu bar at the top of the screen</i> (not the ribbon). ' +
    'Write the path with <code>&gt;</code>: <code>Format &gt; Font...</code>. It must match your copy of ' +
    esc(a.label) + ' in its <b>display language</b> — on a French system you write <code>Format &gt; Police...</code>. ' +
    'That is why no built-in shortcut uses a menu path.</p>';
  const scripts = {
    excel:
      '<p><b>3 · AppleScript</b> — the most powerful: your text runs inside ' +
      '<code>tell application "Microsoft Excel" … end tell</code>, so write only the action. ' +
      '<code>selection</code> = the selected cells.<br>' +
      '<code>set font size of font object of selection to 14</code><br>' +
      '<code>set row height of entire row of selection to 30</code><br>' +
      '<code>set zoom of active window to 150</code></p>',
    word:
      '<p><b>3 · AppleScript</b> — your text runs inside ' +
      '<code>tell application "Microsoft Word" … end tell</code>. ' +
      '<code>selection</code> = the selected text; formatting hangs off <code>font object</code> ' +
      'and <code>paragraph format</code>.<br>' +
      '<code>set bold of font object of selection to true</code><br>' +
      '<code>set font size of font object of selection to 14</code><br>' +
      '<code>set color index of font object of selection to red</code></p>',
    powerpoint:
      '<p><b>3 · AppleScript</b> — your text runs inside ' +
      '<code>tell application "Microsoft PowerPoint" … end tell</code>. ' +
      'PowerPoint\'s dictionary is thinner than Excel\'s and most of it reaches slides through ' +
      '<code>document window 1</code>, so keystrokes are usually the better tool here.<br>' +
      '<code>go to slide 3 of document window 1</code><br>' +
      '<code>set zoom of view of document window 1 to 120</code></p>',
  };
  return common + (scripts[a.id] || '') +
    '<p class="gnote">Editing a built-in makes it yours; built-ins marked ⚙ keep their smart action ' +
    '(only sequence and name can change). Every host keeps its own separate list.</p>';
}

// ----------------------------------------------------------------- pages
function pageHTML(a) {
  const id = a.id;
  return '<main id="page-' + id + '" class="page">' +
    '<div class="toggle">' +
      '<div class="sw-wrap">' +
        '<label class="sw"><input type="checkbox" id="en-' + id + '" ' +
          'onchange="send({op:\'appenabled\', app:\'' + id + '\', on:this.checked})">' +
          '<span>Enable ⌥ shortcuts in ' + esc(a.label) + '</span></label>' +
        '<div class="note">When off, ' + esc(a.label) + ' keeps its own ⌥ behaviour untouched.</div>' +
        '<label class="sw" style="margin-top:9px"><input type="checkbox" id="ovl-' + id + '" ' +
          'onchange="send({op:\'overlay\', on:this.checked})">' +
          '<span>Show KeyTips overlay</span></label>' +
        '<div class="note">For experts who know sequences by heart.</div>' +
      '</div>' +
      '<input class="search" id="search-' + id + '" type="search" placeholder="Search shortcuts…" ' +
        'oninput="applyFilter(\'' + id + '\')">' +
    '</div>' +
    '<div class="off" id="off-' + id + '">Shortcuts are switched off for ' + esc(a.label) +
      ' — the list below is inactive until you re-enable it.</div>' +
    '<div class="addbar">' +
      '<input class="sq" id="seq-' + id + '" placeholder="hxx" maxlength="6">' +
      '<input class="ds" id="desc-' + id + '" placeholder="What it does">' +
      '<select id="kind-' + id + '" onchange="hintParam(\'' + id + '\')">' +
        '<option value="keystroke">Keystroke</option>' +
        '<option value="menu">Menu path</option>' +
        '<option value="applescript">AppleScript</option>' +
      '</select>' +
      '<input class="pm" id="param-' + id + '" placeholder="cmd+shift+t">' +
      '<button class="go" id="save-' + id + '" onclick="save(\'' + id + '\')">Add shortcut</button>' +
      '<button class="cancel" id="cancel-' + id + '" onclick="resetForm(\'' + id + '\')">Cancel</button>' +
    '</div>' +
    '<p class="err" id="err-' + id + '"></p>' +
    '<details class="guide"><summary>How to create shortcuts — the three methods</summary>' +
      '<div class="g">' + guideFor(a) + '</div></details>' +
    '<table><thead><tr><th>Sequence</th><th>Action</th><th>Command</th><th></th><th></th><th></th></tr></thead>' +
    '<tbody id="rows-' + id + '"></tbody></table>' +
    '<p class="fblink">Using XL every day? <a onclick="showPage(\'fb\')">Tell me what you think →</a></p>' +
  '</main>';
}

function render(list) {
  apps = list;
  if (!$('tabs').dataset.built) {
    $('tabs').innerHTML = list.map(a =>
      '<button id="tab-' + a.id + '" onclick="showPage(\'' + a.id + '\')">' + esc(a.label) + '</button>').join('') +
      '<button id="tab-fb" onclick="showPage(\'fb\')">Feedback</button>';
    $('pages').innerHTML = list.map(pageHTML).join('');
    $('tabs').dataset.built = '1';
  }
  list.forEach(a => {
    if (!state[a.id]) state[a.id] = { all: [], items: [], editing: null };
    state[a.id].all = a.items || [];
    const en = $('en-' + a.id);
    if (en) en.checked = a.enabled !== false;
    const off = $('off-' + a.id);
    if (off) off.style.display = a.enabled === false ? 'block' : 'none';
    applyFilter(a.id);
  });
  showPage(current || (list[0] && list[0].id));
}

function applyTheme(a) {
  if (!a) return;
  const r = document.documentElement.style;
  r.setProperty('--accent', a.accent);
  r.setProperty('--accent2', a.accent2);
  r.setProperty('--accentDark', a.accentDark);
}

function showPage(which) {
  if (!which) return;
  current = which;
  apps.forEach(a => {
    const p = $('page-' + a.id), t = $('tab-' + a.id);
    if (p) p.className = 'page' + (which === a.id ? ' on' : '');
    if (t) t.className = (which === a.id ? 'on' : '');
  });
  $('page-fb').className = 'page' + (which === 'fb' ? ' on' : '');
  $('tab-fb').className = (which === 'fb' ? 'on' : '');
  const host = apps.filter(x => x.id === which)[0];
  applyTheme(host || apps[0]);
  $('sub').textContent = which === 'fb'
    ? 'Tell me what works and what is missing.'
    : 'Tap ⌥ in ' + (host ? host.label : '') + ', then type a sequence. Changes apply instantly.';
  if (which === 'fb') send({ op: 'loadstats' });
}

// ------------------------------------------------------------------ rows
function applyFilter(id) {
  const st = state[id]; if (!st) return;
  const box = $('search-' + id);
  const q = ((box && box.value) || '').trim().toLowerCase();
  st.items = !q ? st.all : st.all.filter(it =>
    (it.seq + ' ' + it.desc + ' ' + (it.cmd || '')).toLowerCase().indexOf(q) >= 0);
  renderRows(id);
}

function renderRows(id) {
  const tb = $('rows-' + id); if (!tb) return;
  tb.innerHTML = '';
  state[id].items.forEach((it, i) => {
    const tr = document.createElement('tr');
    tr.innerHTML =
      '<td class="seq">' + esc(it.seq.toUpperCase().split('').join(' ')) + '</td>' +
      '<td>' + esc(it.desc) + '</td>' +
      '<td class="cmd" title="' + esc(it.cmd) + '">' + (it.luaKind ? '⚙ ' : '') + esc(it.cmd) + '</td>' +
      '<td><span class="tag' + (it.builtin ? '' : ' custom') + '">' + (it.builtin ? 'built-in' : 'custom') + '</span></td>' +
      '<td><button class="edit" onclick="beginEdit(\'' + id + '\',' + i + ')">Edit</button></td>' +
      '<td style="text-align:right"><button class="del" onclick="removeIt(\'' + id + '\',' + i + ')">Remove</button></td>';
    tb.appendChild(tr);
  });
}

function hintParam(id) {
  const k = $('kind-' + id).value;
  $('param-' + id).placeholder =
    k === 'menu' ? 'Format > Font...' : k === 'applescript' ? 'set bold of font object of selection to true' : 'cmd+shift+t';
}

function beginEdit(id, i) {
  const it = state[id].items[i];
  state[id].editing = { orig: it.orig, builtin: it.builtin, luaKind: !!it.luaKind };
  $('seq-' + id).value = it.seq;
  $('desc-' + id).value = it.desc;
  $('kind-' + id).value = it.luaKind ? 'keystroke' : it.kind;
  $('param-' + id).value = it.param || '';
  $('kind-' + id).disabled = it.luaKind;
  $('param-' + id).disabled = it.luaKind;
  $('save-' + id).textContent = 'Save changes';
  $('cancel-' + id).style.display = 'inline-block';
  showErr(id, '');
}

function resetForm(id) {
  state[id].editing = null;
  ['seq-', 'desc-', 'param-'].forEach(p => $(p + id).value = '');
  $('kind-' + id).disabled = false;
  $('param-' + id).disabled = false;
  $('save-' + id).textContent = 'Add shortcut';
  $('cancel-' + id).style.display = 'none';
  showErr(id, '');
}

function showErr(id, t) {
  const e = $('err-' + id);
  e.textContent = t; e.style.display = t ? 'block' : 'none';
}

function save(id) {
  const seq = $('seq-' + id).value.trim().toLowerCase();
  const desc = $('desc-' + id).value.trim();
  const kind = $('kind-' + id).value;
  const param = $('param-' + id).value.trim();
  const editing = state[id].editing;
  if (!seq) { showErr(id, 'Sequence is required (e.g. hxx).'); return; }
  const needsParam = !(editing && editing.luaKind);
  if (needsParam && !param) { showErr(id, 'Command is required: keys like cmd+shift+t, a menu path, or a script.'); return; }
  if (editing) {
    send({ op: 'edit', app: id, orig: editing.orig, builtin: editing.builtin, luaKind: editing.luaKind,
           seq: seq, desc: desc || 'Custom', kind: kind, param: param });
  } else {
    send({ op: 'add', app: id, seq: seq, desc: desc || 'Custom', kind: kind, param: param });
  }
  resetForm(id);
}

function removeIt(id, i) {
  const it = state[id].items[i];
  send({ op: 'delete', app: id, seq: it.seq, orig: it.orig, builtin: it.builtin });
}

// -------------------------------------------------------------- feedback
let rating = 0;

document.addEventListener('DOMContentLoaded', function () {
  document.querySelectorAll('#stars span').forEach(function (el) {
    el.onclick = function () {
      rating = parseInt(el.getAttribute('data-v'), 10);
      document.querySelectorAll('#stars span').forEach(function (o) {
        o.className = parseInt(o.getAttribute('data-v'), 10) <= rating ? 'lit' : '';
      });
    };
  });
});

function sendFeedback() {
  const text = $('fb-text').value.trim();
  const contact = $('fb-contact').value.trim();
  if (!rating) { alert('Please pick a star rating first.'); return; }
  send({ op: 'feedback', rating: rating, comment: text, contact: contact });
}

function feedbackDone(ok) {
  if (!ok) return;
  $('fb-done').style.display = 'block';
  $('fb-text').value = '';
}

function setStats(s) {
  if (s.average) {
    $('statsbar').style.display = 'flex';
    $('st-avg').textContent = Number(s.average).toFixed(1) + '★';
    $('st-n').textContent = s.ratings != null ? s.ratings : '–';
    $('st-c').textContent = s.comments != null ? s.comments : '–';
  }
}

function setStatus(ok) { $('ax').style.display = ok ? 'none' : 'flex'; }
function setOverlay(on) {
  apps.forEach(a => { const b = $('ovl-' + a.id); if (b) b.checked = !!on; });
}
send({ op: 'load' });
</script></body></html>
]==]

function pushCatalogRef() end   -- forward declaration (set below)
local function pushCatalog()
  if not ExcelAlt.manager then return end
  local payload = {}
  for _, a in ipairs(APPS) do
    payload[#payload + 1] = {
      id = a.id, label = a.label, noun = a.noun, as = a.as,
      accent = a.accent, accent2 = a.accent2, accentDark = a.accentDark,
      enabled = ExcelAlt.appEnabled[a.id] ~= false,
      items = CATALOG[a.id] or {},
    }
  end
  ExcelAlt.manager:evaluateJavaScript("render(" .. hs.json.encode(payload) .. ")")
  ExcelAlt.manager:evaluateJavaScript("setStatus(" .. tostring(hs.accessibilityState() == true) .. ")")
  ExcelAlt.manager:evaluateJavaScript("setOverlay(" .. tostring(ExcelAlt.overlayOn == true) .. ")")
end
pushCatalogRef = pushCatalog

local function savePrefs()
  writeJSON(PREFS, {
    enabled = ExcelAlt.enabled,
    overlayOn = ExcelAlt.overlayOn,
    appEnabled = ExcelAlt.appEnabled,
  })
end

local function saveStore()
  -- Mirror the Excel slice to the top level so a rollback to v3.1 or
  -- earlier still finds the user's Excel customs where it expects them.
  local xlSlice = slice("excel")
  store.custom, store.disabled, store.renames = xlSlice.custom, xlSlice.disabled, xlSlice.renames
  writeJSON(STORE, store)
  rebuild()
  pushCatalog()
end

-- Manager operations (shared by the webview bridge and the test suite).
-- Every one is scoped to a host id; it defaults to Excel so the older
-- call signature used by earlier tests still means what it used to.
local function opDelete(seq, appId)
  local sl = slice(appId or "excel")
  local kept, wasCustom = {}, false
  for _, c in ipairs(sl.custom) do
    if c.seq:lower() == seq then wasCustom = true else kept[#kept + 1] = c end
  end
  sl.custom = kept
  if not wasCustom then sl.disabled[seq] = true end
  saveStore()
end

local function entryFrom(b)
  local entry = { seq = b.seq, desc = b.desc, kind = b.kind }
  if b.kind == "keystroke" then
    local key = b.param:match("([^+]+)$") or b.param
    local mods = b.param:sub(1, #b.param - #key):gsub("%+$", "")
    entry.key, entry.mods = key, mods
  elseif b.kind == "menu" then
    entry.path = b.param
  else
    entry.script = b.param
  end
  return entry
end

local function putCustom(sl, entry, replacingSeq)
  local kept = {}
  for _, c in ipairs(sl.custom) do
    local cs = c.seq:lower()
    if cs ~= entry.seq:lower() and cs ~= (replacingSeq or ""):lower() then
      kept[#kept + 1] = c
    end
  end
  kept[#kept + 1] = entry
  sl.custom = kept
end

local function opAdd(b)
  local sl = slice(b.app or "excel")
  sl.disabled[b.seq] = nil
  putCustom(sl, entryFrom(b))
  saveStore()
end

local function opEdit(b)
  local sl = slice(b.app or "excel")
  if b.builtin and b.luaKind then
    -- smart built-ins keep their action; only sequence/name change
    sl.renames[b.orig] = { seq = b.seq, desc = b.desc }
  elseif b.builtin then
    -- editing a plain built-in turns it into a custom that shadows it
    sl.disabled[b.orig] = true
    sl.renames[b.orig] = nil
    putCustom(sl, entryFrom(b))
  else
    putCustom(sl, entryFrom(b), b.orig)
  end
  saveStore()
end

local function openManager()
  if ExcelAlt.manager then
    ExcelAlt.manager:show()
    pcall(function()
      hs.application.applicationForPID(hs.processInfo.processID):activate(true)
    end)
    pushCatalog()
    return
  end
  ExcelAlt.ucc = hs.webview.usercontent.new("xl"):setCallback(function(msg)
    local b = msg.body
    if b.op == "load" then pushCatalog()
    elseif b.op == "feedback" then
      local ok = sendFeedback(b.rating, b.comment, b.contact)
      ExcelAlt.manager:evaluateJavaScript("feedbackDone(" .. tostring(ok) .. ")")
      pcall(pushStatsToUI)
    elseif b.op == "loadstats" then
      pcall(pushStatsToUI)
      refreshStats()
    elseif b.op == "overlay" then
      ExcelAlt.overlayOn = (b.on == true)
      savePrefs()
      if not ExcelAlt.overlayOn then pcall(overlayHide) end
    elseif b.op == "appenabled" then
      if APP[b.app] then
        ExcelAlt.appEnabled[b.app] = (b.on == true)
        savePrefs()
        updateTaps()
      end
    elseif b.op == "axsettings" then
      hs.execute("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'")
    elseif b.op == "delete" then
      if b.builtin and b.orig then
        local sl = slice(b.app or "excel")
        sl.disabled[b.orig] = true
        sl.renames[b.orig] = nil
        saveStore()
      else
        opDelete(b.seq, b.app)
      end
    elseif b.op == "edit" then opEdit(b)
    elseif b.op == "add" then opAdd(b) end
  end)

  local scr = hs.screen.mainScreen():frame()
  local W, H = 780, 600
  local html = MANAGER_HTML
  local corgiPath = hs.processInfo.resourcePath .. "/xl-corgi.png"
  if fileExists(corgiPath) then
    local f = io.open(corgiPath, "rb")
    local data = f:read("*a") ; f:close()
    html = html:gsub("CORGI_SRC", "data:image/png;base64," .. hs.base64.encode(data), 1)
  else
    html = html:gsub("CORGI_SRC", "", 1)
  end
  ExcelAlt.manager = hs.webview.new(
      { x = scr.x + (scr.w - W) / 2, y = scr.y + (scr.h - H) / 2, w = W, h = H },
      { developerExtrasEnabled = false }, ExcelAlt.ucc)
    :windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    :windowTitle(APPNAME .. " Shortcut Manager")
    :allowTextEntry(true)
    :deleteOnClose(false)
    :html(html)
  pcall(function() ExcelAlt.manager:level(hs.drawing.windowLevels.normal) end)
  pcall(function() ExcelAlt.manager:shadow(true) end)   -- standard macOS window shadow
  ExcelAlt.manager:show()
  -- NEVER call bringToFront() here: hs.webview implements it by raising the
  -- window to floating level, which pins it above every other app.
  pcall(function()
    hs.application.applicationForPID(hs.processInfo.processID):activate(true)
  end)
end

-- ---------------------------------------------------------------------
-- Menu bar
-- ---------------------------------------------------------------------
local function menubarMenu()
  local accessOK = hs.accessibilityState()
  local hostItems = {}
  for _, a in ipairs(APPS) do
    hostItems[#hostItems + 1] = {
      title = (ExcelAlt.appEnabled[a.id] ~= false and "✓ " or "    ") .. a.label,
      fn = function()
        ExcelAlt.appEnabled[a.id] = (ExcelAlt.appEnabled[a.id] == false)
        savePrefs()
        updateTaps()
        pcall(pushCatalogRef)
      end }
  end
  return {
    { title = ExcelAlt.enabled and "✓ Shortcuts enabled" or "Shortcuts paused",
      fn = function()
        ExcelAlt.enabled = not ExcelAlt.enabled
        savePrefs()
        updateTaps()
      end },
    { title = "Active in…", menu = hostItems },
    { title = ExcelAlt.overlayOn and "✓ Show KeyTips overlay" or "KeyTips overlay hidden",
      fn = function()
        ExcelAlt.overlayOn = not ExcelAlt.overlayOn
        savePrefs()
        if not ExcelAlt.overlayOn then overlayHide() end
        pcall(pushCatalogRef)
      end },
    { title = "-" },
    { title = "Shortcut Manager…", fn = openManager },
    { title = "-" },
    { title = accessOK and "Accessibility: granted"
                        or "Grant Accessibility permission…",
      disabled = accessOK,
      fn = function()
        hs.osascript.applescript([[tell application "System Settings"
          activate
          reveal anchor "Privacy_Accessibility" of pane id "com.apple.settings.PrivacySecurity"
        end tell]])
      end },
    { title = "-" },
    { title = "Quit " .. APPNAME, fn = function() os.exit() end },
  }
end

local function setupMenubar()
  -- If an item already exists AND macOS reports it on the bar, keep it.
  if ExcelAlt.bar then
    local ok, inBar = pcall(function() return ExcelAlt.bar:isInMenuBar() end)
    if ok and inBar == true then
      ExcelAlt.bar:setMenu(menubarMenu)
      return
    end
    pcall(function() ExcelAlt.bar:delete() end)
    ExcelAlt.bar = nil
  end
  -- Fresh autosave identity sidesteps any per-item state macOS persists
  -- (older engines accept only the first argument; fall back cleanly).
  local okNew, bar = pcall(hs.menubar.new, true, "xl" .. tostring(os.time()))
  ExcelAlt.bar = (okNew and bar) or hs.menubar.new()
  if not ExcelAlt.bar then dlog("menubar: hs.menubar.new() returned nil") ; return end
  local p = hs.processInfo.resourcePath .. "/xl-menubar@2x.png"
  if fileExists(p) then
    local img = hs.image.imageFromPath(p)
    if img then
      img = img:setSize({ w = 18, h = 18 })
      img = img:template(true)
      ExcelAlt.barIcon = img
      ExcelAlt.bar:setIcon(img, true)  -- explicit template: auto-adapts to dark menu bars
    end
  end
  -- Title is ALWAYS set: if the status item exists, text cannot be
  -- invisible, so presence/absence of "⌥XL" in the menu bar is a
  -- definitive diagnostic (icon-only could hide via rendering issues).
  ExcelAlt.bar:setTitle("⌥XL")
  ExcelAlt.bar:setTooltip(APPNAME .. " — Alt shortcuts for Excel, PowerPoint & Word")
  ExcelAlt.bar:setMenu(menubarMenu)
  dlog("menubar: item created; icon=" .. tostring(ExcelAlt.barIcon ~= nil))
  -- Half a second later, record what macOS actually DID with the item:
  -- on the bar or not, and at which screen coordinates.
  hs.timer.doAfter(0.5, function()
    local okI, inBar = pcall(function() return ExcelAlt.bar and ExcelAlt.bar:isInMenuBar() end)
    local okF, fr   = pcall(function() return ExcelAlt.bar and ExcelAlt.bar:frame() end)
    local scr = hs.screen.mainScreen():frame()
    dlog(string.format("menubar: visible=%s frame=%s screen=%dx%d",
      tostring(okI and inBar),
      (okF and fr) and string.format("(%.0f,%.0f %.0fx%.0f)", fr.x, fr.y, fr.w, fr.h) or "n/a",
      scr.w, scr.h))
    -- Zero-height frame = window never laid out into the bar: force a
    -- remove/return cycle, which makes the status bar lay it out afresh.
    if okF and fr and fr.h == 0 then
      dlog("menubar: zero-height layout; forcing remove/return re-layout")
      pcall(function() ExcelAlt.bar:removeFromMenuBar() end)
      hs.timer.doAfter(0.3, function()
        pcall(function() ExcelAlt.bar:returnToMenuBar() end)
        hs.timer.doAfter(0.5, function()
          local _, fr2 = pcall(function() return ExcelAlt.bar and ExcelAlt.bar:frame() end)
          dlog("menubar: after re-layout frame=" ..
            (fr2 and string.format("(%.0f,%.0f %.0fx%.0f)", fr2.x, fr2.y, fr2.w, fr2.h) or "n/a"))
        end)
      end)
    end
  end)
end

-- ---------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------
local prefs = readJSON(PREFS)
if prefs then
  if prefs.enabled == false then ExcelAlt.enabled = false end
  if prefs.overlayOn == false then ExcelAlt.overlayOn = false end
  if type(prefs.appEnabled) == "table" then
    for _, a in ipairs(APPS) do
      if prefs.appEnabled[a.id] == false then ExcelAlt.appEnabled[a.id] = false end
    end
  end
end

ExcelAlt.flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, safely(handleFlags))
ExcelAlt.keyTap   = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, safely(handleKey))

-- One-time frontmost check at startup (allowed here: not inside a tap)
do
  local f = hs.application.frontmostApplication()
  local bid = f ~= nil and f:bundleID() or nil
  ExcelAlt.activeApp = bid and BY_BUNDLE[bid:lower()] or nil
  ExcelAlt.excelFront = (ExcelAlt.activeApp == "excel")
end

ExcelAlt.watcher = hs.application.watcher.new(onAppEvent)
ExcelAlt.watcher:start()

-- If the status item was ever ⌘-dragged off the menu bar or hidden by a
-- menu-bar manager, macOS persists "NSStatusItem Visible…=false" in this
-- app's preferences and every future item is created INVISIBLE (creation
-- still succeeds — matching our logs exactly). Purge any such flags.
pcall(function()
  for _, k in ipairs(hs.settings.getKeys() or {}) do
    if k:find("^NSStatusItem") then
      dlog("menubar: clearing hidden-state pref '" .. k .. "'")
      hs.settings.clear(k)
    end
  end
end)

-- Menu bar item is created ONLY after launch settles: creating it during
-- the agent->regular transform lets macOS destroy it. First creation at
-- +2s; safety rebuilds at +6s and after permission grant.
dlog("startup: engine v" .. ExcelAlt.version .. " loaded from " ..
     tostring(hs.processInfo.bundlePath or "?") .. " | configdir=" ..
     tostring(hs.configdir) .. " | menubar deferred")

-- The underlying runtime may open its console or preferences window on
-- first launch (before our own settings apply). Close anything that
-- isn't ours, now and shortly after launch.
local function hideEngineWindows()
  pcall(function()
    if hs.console and hs.console.hswindow then
      local cw = hs.console.hswindow()
      if cw then cw:close() end
    end
    local me = hs.application.applicationForPID(hs.processInfo.processID)
    if me then
      for _, w in ipairs(me:allWindows() or {}) do
        local t = w:title() or ""
        if t:find("Hammerspoon") or t:find("Console") or t:find("Preferences") then
          w:close()
        end
      end
    end
  end)
end
hideEngineWindows()
hs.timer.doAfter(1, hideEngineWindows)
hs.timer.doAfter(3, hideEngineWindows)

-- The Shortcut Manager is the app's visible face: open it on launch so
-- the person always lands on the shortcut table, not engine windows.
-- Dock icon clicks reopen it (and never the engine console).
pcall(function() hs.openConsoleOnDockClick(false) end)
hs.dockIconClickCallback = function() pcall(openManager) end
pcall(openManager)

-- The launch-time agent->regular-app transform is known to destroy status
-- items created before it completes: rebuild ours once things settle.
hs.timer.doAfter(2, setupMenubar)
hs.timer.doAfter(6, setupMenubar)
-- Last resort at +12s: if macOS still refuses to show the item, rebuild it
-- as text-only ("⌥XL"), the most primitive form a status item can take.
hs.timer.doAfter(12, function()
  local ok, inBar = pcall(function() return ExcelAlt.bar and ExcelAlt.bar:isInMenuBar() end)
  if not (ok and inBar == true) then
    dlog("menubar: STILL not visible; last-resort text-only rebuild")
    pcall(function() ExcelAlt.bar:delete() end)
    ExcelAlt.bar = hs.menubar.new()
    if ExcelAlt.bar then
      ExcelAlt.bar:setTitle("⌥XL")
      ExcelAlt.bar:setMenu(menubarMenu)
    end
  end
end)

-- Cmd+Q support: a hotkey active ONLY while ExcelAlt is the frontmost app
-- (enabled/disabled by the app watcher above). Requires Accessibility, so
-- it activates in the steady state; menu bar Quit and Dock right-click
-- Quit work regardless.
pcall(function()
  ExcelAlt.quitKey = hs.hotkey.new({"cmd"}, "q", function() os.exit() end)
end)

local function grantReady()
  dlog("accessibility granted; starting taps")
  ExcelAlt.tapsReady = true
  -- Taps created before trust was granted can be stale: rebuild them now
  -- so the first grant works immediately, without toggling permissions.
  pcall(function() ExcelAlt.flagsTap:stop() end)
  pcall(function() ExcelAlt.keyTap:stop() end)
  ExcelAlt.flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, safely(handleFlags))
  ExcelAlt.keyTap   = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, safely(handleKey))
  updateTaps()
  -- With permission granted, window enumeration works: sweep away any
  -- engine console/preferences window that appeared during first run.
  hideEngineWindows()
  hs.timer.doAfter(1, hideEngineWindows)
  pcall(pushCatalog)
  hs.timer.doAfter(1, setupMenubar)
  hs.alert.show(APPNAME .. " ready — tap ⌥ in Excel, PowerPoint or Word", 1.5)
end

-- Live trust tracking: grant activates taps in place (no restart); revoke
-- stops them and brings the red banner back in the manager immediately.
function refreshTrust()
  local trusted = hs.accessibilityState() == true
  if trusted and not ExcelAlt.tapsReady then
    grantReady()
  elseif (not trusted) and ExcelAlt.tapsReady then
    ExcelAlt.tapsReady = false
    updateTaps()
    dlog("accessibility revoked; taps stopped, banner restored")
  end
  pcall(pushCatalog)
end

-- macOS broadcasts this notification whenever Accessibility grants change
pcall(function()
  ExcelAlt.axWatch = hs.distributednotifications.new(function()
    hs.timer.doAfter(0.5, refreshTrust)
  end, "com.apple.accessibility.api")
  ExcelAlt.axWatch:start()
end)

if hs.accessibilityState(true) then
  grantReady()
else
  hs.alert.show(APPNAME .. " needs Accessibility permission\n(System Settings → Privacy & Security)", 4)
  -- Taps opened before permission never attach; poll and start once granted
  ExcelAlt.permTimer = hs.timer.doEvery(1, function()
    if hs.accessibilityState() then
      ExcelAlt.permTimer:stop()
      ExcelAlt.permTimer = nil
      refreshTrust()
    end
  end)
end

-- ---------------------------------------------------------------------
-- Test hooks (inert in production; used by tests/run_tests.lua)
-- ---------------------------------------------------------------------
ExcelAlt._test = {
  adjustFormat = adjustFormat,
  handleFlags  = handleFlags,
  handleKey    = handleKey,
  onAppEvent   = onAppEvent,
  updateTaps   = updateTaps,
  rebuild      = rebuild,
  sendFeedback = sendFeedback,
  opAdd        = opAdd,
  opEdit       = opEdit,
  opDelete     = opDelete,
  savePrefs    = savePrefs,
  apps         = APPS,
  byBundle     = BY_BUNDLE,
  builtins     = BUILTINS,
  store        = function() return store end,
  -- Host-scoped views; default to Excel so pre-multi-app assertions still
  -- read the set they were written against.
  exact        = function(appId) return EXACT[appId or "excel"] end,
  prefixes     = function(appId) return PREFIX[appId or "excel"] end,
  catalog      = function(appId) return CATALOG[appId or "excel"] end,
}
