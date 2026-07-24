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
-- =====================================================================

-- Global state table FIRST (v8 crash fix: never index before init)
ExcelAlt = {
  version    = "2.3",
  enabled    = true,
  overlayOn  = true,   -- KeyTips panel; expert users can switch it off
  mode       = false,
  seq        = "",
  excelFront = false,  -- cached by the app watcher; NEVER queried per-event
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

local EXCEL   = "com.microsoft.Excel"
local SELF_BUNDLE = (hs.processInfo and hs.processInfo.bundleID) or "com.corgianalyst.excel-alt-shortcuts"
local APPNAME = "⌥XL"
local SEQ_TIMEOUT = 4

-- ---------------------------------------------------------------------
-- Paths & persistence (own Application Support dir, never Hammerspoon's)
-- ---------------------------------------------------------------------
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
-- Excel helpers
-- ---------------------------------------------------------------------
local function excelApp()
  return hs.application.get(EXCEL)
end

local function stroke(mods, key)
  return function()
    local app = excelApp()
    hs.eventtap.keyStroke(mods, key, 0, app)
  end
end

-- Click a menu item by path; final element falls back to prefix match
local function menu(path)
  return function()
    local app = excelApp(); if not app then return end
    if app:selectMenuItem(path) then return end
    local pat = "^" .. path[#path]:gsub("%p", "%%%1")
    local p2 = {}
    for i = 1, #path - 1 do p2[i] = path[i] end
    p2[#path] = pat
    app:selectMenuItem(p2, true)
  end
end

-- Click a menu path; if the item can't be found (localization, version
-- differences), run the AppleScript fallback instead.
local function menuThen(path, fallbackFn)
  return function()
    local app = excelApp(); if not app then return end
    if app:selectMenuItem(path) then return end
    local pat = "^" .. path[#path]:gsub("%p", "%%%1")
    local p2 = {}
    for i = 1, #path - 1 do p2[i] = path[i] end
    p2[#path] = pat
    if app:selectMenuItem(p2, true) then return end
    if fallbackFn then fallbackFn() end
  end
end

local function ascript(body)
  return function()
    hs.osascript.applescript('tell application "Microsoft Excel"\n' .. body .. '\nend tell')
  end
end

local function border(edge, style, weight)
  style  = style  or "continuous"
  weight = weight or "border weight thin"
  return ascript(string.format(
    'set b to (get border of selection which border %s)\nset line style of b to %s\nset weight of b to %s',
    edge, style, weight))
end

local function noBorders()
  return ascript([[
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
  return ascript(table.concat(lines, "\n"))
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
  return ascript('set number format of selection to "' .. fmt .. '"')
end

-- ---------------------------------------------------------------------
-- Built-in shortcut map (declarative: every entry knows its own command,
-- so the manager can display and edit it)
-- ---------------------------------------------------------------------
local BUILTIN = {
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

-- ---------------------------------------------------------------------
-- Custom shortcuts + disabled built-ins (manager persistence)
-- ---------------------------------------------------------------------
local store = readJSON(STORE) or { custom = {}, disabled = {} }
store.custom, store.disabled = store.custom or {}, store.disabled or {}
store.renames = store.renames or {}

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

-- One factory for built-ins AND customs: entry -> executable function
local function fnFor(e)
  if e.kind == "lua" then
    return e.fn
  elseif e.kind == "keystroke" then
    return stroke(parseMods(e.mods), e.key or "")
  elseif e.kind == "menu" then
    return menuThen(parsePath(e.path), e.fallback and ascript(e.fallback) or nil)
  else
    return ascript(e.script or "")
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

local exact, prefixes, catalog = {}, {}, {}


local function rebuild()
  exact, prefixes, catalog = {}, {}, {}
  local function add(seq, desc, fn, builtin, meta)
    exact[seq] = { desc = desc, fn = fn }
    for i = 1, #seq - 1 do prefixes[seq:sub(1, i)] = true end
    local row = { seq = seq, desc = desc, builtin = builtin }
    for k, v in pairs(meta or {}) do row[k] = v end
    catalog[#catalog + 1] = row
  end
  for _, b in ipairs(BUILTIN) do
    if not store.disabled[b.seq] then
      local r = store.renames[b.seq] or {}
      local seq  = (r.seq and #r.seq > 0) and r.seq:lower() or b.seq
      local desc = (r.desc and #r.desc > 0) and r.desc or b.desc
      add(seq, desc, fnFor(b), true, {
        orig = b.seq, kind = b.kind, luaKind = (b.kind == "lua"),
        cmd = cmdFor(b), param = paramFor(b) })
    end
  end
  for _, c in ipairs(store.custom) do
    if c.seq and #c.seq > 0 then
      add(c.seq:lower(), c.desc or "Custom", fnFor(c), false, {
        orig = c.seq, kind = c.kind, luaKind = false,
        cmd = cmdFor(c), param = paramFor(c) })
    end
  end
  table.sort(catalog, function(a, b) return a.seq < b.seq end)
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
  local hints = {}
  for _, item in ipairs(catalog) do
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
    textSize = 17, textColor = { hex = "#F5C542" },
    frame = { x = PAD, y = PAD - 2, w = W - PAD * 2, h = 26 } })
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
  if not ExcelAlt.enabled or not ExcelAlt.excelFront then return false end
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
  if not ExcelAlt.enabled or not ExcelAlt.excelFront then
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

  local hit = exact[ExcelAlt.seq]
  if hit then
    exitMode()
    if ExcelAlt.overlayOn then say(hit.desc, 0.8) end   -- expert mode: silent success
    hs.timer.doAfter(0.05, hit.fn)   -- action runs OUTSIDE the tap callback
    return true
  elseif prefixes[ExcelAlt.seq] then
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
  local want = ExcelAlt.tapsReady and ExcelAlt.excelFront and ExcelAlt.enabled
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
  local isExcel = bid == EXCEL
  if event == w.activated then
    ExcelAlt.excelFront = isExcel
  elseif isExcel then          -- Excel deactivated or quit
    ExcelAlt.excelFront = false
  else
    return                     -- some other app went away: nothing changes
  end
  updateTaps()
end

-- ---------------------------------------------------------------------
-- Shortcut Manager window
-- ---------------------------------------------------------------------
local MANAGER_HTML = [==[
<!doctype html><html><head><meta charset="utf-8"><style>
:root { --green:#0F6A3F; --green2:#1F8A55; --gold:#F5C542; --ink:#1c211e; --paper:#F7F5EF; }
* { box-sizing:border-box; margin:0; font-family:-apple-system,'SF Pro Text',Helvetica,sans-serif; }
body { background:var(--paper); color:var(--ink); padding:0 0 40px; }
header { background:linear-gradient(180deg,var(--green2),var(--green)); color:#fff;
  padding:16px 24px; display:flex; align-items:center; gap:14px; }
header img { width:44px; height:44px; border-radius:10px; }
header h1 { font-size:19px; font-weight:700; }
header p { font-size:12px; opacity:.85; margin-top:2px; }
main { padding:18px 24px; max-width:860px; margin:0 auto; }
table { width:100%; border-collapse:collapse; background:#fff; border-radius:10px; overflow:hidden;
  box-shadow:0 1px 4px rgba(0,0,0,.08); }
th { text-align:left; font-size:11px; text-transform:uppercase; letter-spacing:.8px;
  color:#6b7570; padding:10px 12px; border-bottom:1px solid #e6e3da; }
td { padding:8px 12px; font-size:13px; border-bottom:1px solid #f0ede5; vertical-align:middle; }
td.seq { font-family:'SF Mono',Menlo,monospace; font-weight:700; color:var(--green); white-space:nowrap; }
td.seq::before { content:'⌥ '; color:var(--gold); }
td.cmd { font-size:11.5px; color:#6b7570; max-width:260px; overflow:hidden;
  text-overflow:ellipsis; white-space:nowrap; }
tr:hover td { background:#fbfaf6; }
.tag { font-size:10px; padding:2px 7px; border-radius:99px; background:#eef3ee; color:#4c6355; }
.tag.custom { background:#fdf3d5; color:#8a6a12; }
button { border:0; border-radius:7px; padding:6px 11px; font-size:12px; cursor:pointer; }
button.edit { background:transparent; color:var(--green); font-weight:600; }
button.edit:hover { background:#e9f2ec; }
button.del { background:transparent; color:#b04a3a; }
button.del:hover { background:#f9e9e6; }
.addbar { display:flex; gap:8px; margin:16px 0 6px; flex-wrap:wrap; align-items:center; }
.addbar input, .addbar select { padding:8px 10px; border:1px solid #d8d4c8; border-radius:7px;
  font-size:13px; background:#fff; }
#f-seq { width:76px; font-family:'SF Mono',Menlo,monospace; }
#f-desc { flex:1; min-width:130px; }
#f-param { flex:2; min-width:190px; }
.addbar .go { background:var(--green); color:#fff; font-weight:600; }
.addbar .go:hover { background:var(--green2); }
.addbar .cancel { background:transparent; color:#6b7570; display:none; }
#err { display:none; color:#b04a3a; font-size:12px; margin:2px 0 6px; font-weight:600; }
.hint { font-size:11.5px; color:#8a877d; margin-bottom:8px; }
.toggle { display:flex; align-items:center; justify-content:space-between; gap:14px; background:#fff;
  border:1px solid #e6e3da; border-radius:10px; padding:11px 14px; margin-top:14px; }
.toggle .sw { display:flex; align-items:center; gap:9px; font-size:13px; font-weight:600; cursor:pointer; }
.toggle .sw input { width:17px; height:17px; accent-color:var(--green); cursor:pointer; }
.toggle .note { font-size:11.5px; color:#8a877d; margin:3px 0 0 26px; }
#search { flex:1; max-width:360px; padding:9px 12px; border:1px solid #d8d4c8; border-radius:8px;
  font-size:13px; background:#fbfaf6; }
#search:focus { outline:2px solid var(--green2); background:#fff; }
#ax { display:none; background:#B04A3A; color:#fff; padding:10px 24px; font-size:13px;
  align-items:center; gap:12px; }
#ax button { background:#fff; color:#B04A3A; font-weight:700; }
</style></head><body>
<header>
  <img src="CORGI_SRC" alt="">
  <div><h1>⌥XL Shortcut Manager</h1>
    <p>Tap ⌥ in Excel, then type a sequence. Changes apply instantly.</p></div>
</header>
<div id="ax">
  <span style="flex:1">Shortcuts are OFF — macOS Accessibility permission is missing.</span>
  <button onclick="send({op:'axsettings'})">Open Accessibility Settings</button>
</div>
<main>
  <div class="toggle">
    <div class="sw-wrap">
      <label class="sw">
        <input type="checkbox" id="ovl" onchange="send({op:'overlay', on: this.checked})">
        <span>Show KeyTips overlay in Excel</span>
      </label>
      <div class="note">For experts who know shortcuts by heart.</div>
    </div>
    <input id="search" type="search" placeholder="Search shortcuts…" oninput="applyFilter()">
  </div>
  <div class="addbar">
    <input id="f-seq" placeholder="hxx" maxlength="6">
    <input id="f-desc" placeholder="What it does">
    <select id="f-kind" onchange="hintParam()">
      <option value="keystroke">Keystroke</option>
      <option value="menu">Menu path</option>
      <option value="applescript">AppleScript</option>
    </select>
    <input id="f-param" placeholder="cmd+shift+t">
    <button class="go" id="f-save" onclick="save()">Add shortcut</button>
    <button class="cancel" id="f-cancel" onclick="resetForm()">Cancel</button>
  </div>
  <p id="err"></p>
  <p class="hint">Keystroke: <b>cmd+shift+t</b> · Menu: your Mac Excel menu bar path like <b>Edit > Clear > All</b> (in Excel's display language) · AppleScript: body runs inside a tell-Excel block. Editing a built-in makes it yours; built-ins marked ⚙ keep their smart action (only sequence and name can change).</p>
  <table><thead><tr><th>Sequence</th><th>Action</th><th>Command</th><th></th><th></th><th></th></tr></thead>
  <tbody id="rows"></tbody></table>
</main>
<script>
let editing = null;   // {orig, builtin, luaKind} while editing
let all = [];         // full catalog from the engine
let items = [];       // currently displayed (filtered) rows

function esc(t) { const d = document.createElement('div'); d.textContent = t == null ? '' : t; return d.innerHTML; }

function render(list) {
  all = list;
  applyFilter();
}

function applyFilter() {
  const q = (document.getElementById('search').value || '').trim().toLowerCase();
  items = !q ? all : all.filter(it =>
    (it.seq + ' ' + it.desc + ' ' + (it.cmd || '')).toLowerCase().includes(q));
  renderRows();
}

function renderRows() {
  const tb = document.getElementById('rows'); tb.innerHTML = '';
  items.forEach((it, i) => {
    const tr = document.createElement('tr');
    tr.innerHTML =
      '<td class="seq">' + esc(it.seq.toUpperCase().split('').join(' ')) + '</td>' +
      '<td>' + esc(it.desc) + '</td>' +
      '<td class="cmd" title="' + esc(it.cmd) + '">' + (it.luaKind ? '⚙ ' : '') + esc(it.cmd) + '</td>' +
      '<td><span class="tag' + (it.builtin ? '' : ' custom') + '">' + (it.builtin ? 'built-in' : 'custom') + '</span></td>' +
      '<td><button class="edit" onclick="beginEdit(' + i + ')">Edit</button></td>' +
      '<td style="text-align:right"><button class="del" onclick="removeIt(' + i + ')">Remove</button></td>';
    tb.appendChild(tr);
  });
}

function hintParam() {
  const k = document.getElementById('f-kind').value;
  document.getElementById('f-param').placeholder =
    k === 'menu' ? 'Edit > Clear > All' : k === 'applescript' ? 'clear contents selection' : 'cmd+shift+t';
}

function beginEdit(i) {
  const it = items[i];
  editing = { orig: it.orig, builtin: it.builtin, luaKind: !!it.luaKind };
  document.getElementById('f-seq').value = it.seq;
  document.getElementById('f-desc').value = it.desc;
  document.getElementById('f-kind').value = it.luaKind ? 'keystroke' : it.kind;
  document.getElementById('f-param').value = it.param || '';
  document.getElementById('f-kind').disabled = it.luaKind;
  document.getElementById('f-param').disabled = it.luaKind;
  document.getElementById('f-save').textContent = 'Save changes';
  document.getElementById('f-cancel').style.display = 'inline-block';
  showErr('');
}

function resetForm() {
  editing = null;
  ['f-seq','f-desc','f-param'].forEach(id => document.getElementById(id).value = '');
  document.getElementById('f-kind').disabled = false;
  document.getElementById('f-param').disabled = false;
  document.getElementById('f-save').textContent = 'Add shortcut';
  document.getElementById('f-cancel').style.display = 'none';
  showErr('');
}

function showErr(t) {
  const e = document.getElementById('err');
  e.textContent = t; e.style.display = t ? 'block' : 'none';
}

function save() {
  const seq = document.getElementById('f-seq').value.trim().toLowerCase();
  const desc = document.getElementById('f-desc').value.trim();
  const kind = document.getElementById('f-kind').value;
  const param = document.getElementById('f-param').value.trim();
  if (!seq) { showErr('Sequence is required (e.g. hxx).'); return; }
  const needsParam = !(editing && editing.luaKind);
  if (needsParam && !param) { showErr('Command is required: keys like cmd+shift+t, a menu path, or a script.'); return; }
  if (editing) {
    send({ op: 'edit', orig: editing.orig, builtin: editing.builtin, luaKind: editing.luaKind,
           seq: seq, desc: desc || 'Custom', kind: kind, param: param });
  } else {
    send({ op: 'add', seq: seq, desc: desc || 'Custom', kind: kind, param: param });
  }
  resetForm();
}

function removeIt(i) {
  const it = items[i];
  send({ op: 'delete', seq: it.seq, orig: it.orig, builtin: it.builtin });
}

function send(msg) { window.webkit.messageHandlers.xl.postMessage(msg); }
function setStatus(ok) { document.getElementById('ax').style.display = ok ? 'none' : 'flex'; }
function setOverlay(on) { document.getElementById('ovl').checked = !!on; }
send({ op: 'load' });
</script></body></html>
]==]

function pushCatalogRef() end   -- forward declaration (set below)
local function pushCatalog()
  if not ExcelAlt.manager then return end
  ExcelAlt.manager:evaluateJavaScript("render(" .. hs.json.encode(catalog) .. ")")
  ExcelAlt.manager:evaluateJavaScript("setStatus(" .. tostring(hs.accessibilityState() == true) .. ")")
  ExcelAlt.manager:evaluateJavaScript("setOverlay(" .. tostring(ExcelAlt.overlayOn == true) .. ")")
end
pushCatalogRef = pushCatalog

local function saveStore()
  writeJSON(STORE, store)
  rebuild()
  pushCatalog()
end

-- Manager operations (shared by the webview bridge and the test suite)
local function opDelete(seq)
  local kept, wasCustom = {}, false
  for _, c in ipairs(store.custom) do
    if c.seq:lower() == seq then wasCustom = true else kept[#kept + 1] = c end
  end
  store.custom = kept
  if not wasCustom then store.disabled[seq] = true end
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

local function putCustom(entry, replacingSeq)
  local kept = {}
  for _, c in ipairs(store.custom) do
    local cs = c.seq:lower()
    if cs ~= entry.seq:lower() and cs ~= (replacingSeq or ""):lower() then
      kept[#kept + 1] = c
    end
  end
  kept[#kept + 1] = entry
  store.custom = kept
end

local function opAdd(b)
  store.disabled[b.seq] = nil
  putCustom(entryFrom(b))
  saveStore()
end

local function opEdit(b)
  if b.builtin and b.luaKind then
    -- smart built-ins keep their action; only sequence/name change
    store.renames[b.orig] = { seq = b.seq, desc = b.desc }
  elseif b.builtin then
    -- editing a plain built-in turns it into a custom that shadows it
    store.disabled[b.orig] = true
    store.renames[b.orig] = nil
    putCustom(entryFrom(b))
  else
    putCustom(entryFrom(b), b.orig)
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
    elseif b.op == "overlay" then
      ExcelAlt.overlayOn = (b.on == true)
      writeJSON(PREFS, { enabled = ExcelAlt.enabled, overlayOn = ExcelAlt.overlayOn })
      if not ExcelAlt.overlayOn then pcall(overlayHide) end
    elseif b.op == "axsettings" then
      hs.execute("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'")
    elseif b.op == "delete" then
      if b.builtin and b.orig then
        store.disabled[b.orig] = true
        store.renames[b.orig] = nil
        saveStore()
      else
        opDelete(b.seq)
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
  return {
    { title = ExcelAlt.enabled and "✓ Shortcuts enabled" or "Shortcuts paused",
      fn = function()
        ExcelAlt.enabled = not ExcelAlt.enabled
        writeJSON(PREFS, { enabled = ExcelAlt.enabled, overlayOn = ExcelAlt.overlayOn })
        updateTaps()
      end },
    { title = ExcelAlt.overlayOn and "✓ Show KeyTips overlay" or "KeyTips overlay hidden",
      fn = function()
        ExcelAlt.overlayOn = not ExcelAlt.overlayOn
        writeJSON(PREFS, { enabled = ExcelAlt.enabled, overlayOn = ExcelAlt.overlayOn })
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
  ExcelAlt.bar = hs.menubar.new()
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
  ExcelAlt.bar:setTooltip(APPNAME .. " — Alt shortcuts for Excel")
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
  end)
end

-- ---------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------
local prefs = readJSON(PREFS)
if prefs then
  if prefs.enabled == false then ExcelAlt.enabled = false end
  if prefs.overlayOn == false then ExcelAlt.overlayOn = false end
end

ExcelAlt.flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, safely(handleFlags))
ExcelAlt.keyTap   = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, safely(handleKey))

-- One-time frontmost check at startup (allowed here: not inside a tap)
do
  local f = hs.application.frontmostApplication()
  ExcelAlt.excelFront = f ~= nil and f:bundleID() == EXCEL
end

ExcelAlt.watcher = hs.application.watcher.new(onAppEvent)
ExcelAlt.watcher:start()

-- If the status item was ever ⌘-dragged off the menu bar or hidden by a
-- menu-bar manager, macOS persists "NSStatusItem Visible…=false" in this
-- app's preferences and every future item is created INVISIBLE (creation
-- still succeeds — matching our logs exactly). Purge any such flags.
pcall(function()
  for _, k in ipairs(hs.settings.getKeys() or {}) do
    if k:find("^NSStatusItem Visible") then
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
  hs.alert.show(APPNAME .. " ready — tap ⌥ in Excel", 1.5)
end

if hs.accessibilityState(true) then
  grantReady()
else
  hs.alert.show(APPNAME .. " needs Accessibility permission\n(System Settings → Privacy & Security)", 4)
  -- Taps opened before permission never attach; poll and start once granted
  ExcelAlt.permTimer = hs.timer.doEvery(1, function()
    if hs.accessibilityState() then
      ExcelAlt.permTimer:stop()
      ExcelAlt.permTimer = nil
      -- A running process caches its trust state: taps granted mid-run
      -- often refuse to attach until relaunch (the "toggle it five times"
      -- syndrome). Restart ourselves once, automatically — the fresh
      -- process starts fully trusted and works on the first toggle.
      dlog("accessibility granted at runtime; self-relaunching for clean trust")
      hs.alert.show(APPNAME .. ": permission granted — restarting…", 1.2)
      local bp = hs.processInfo.bundlePath
      if bp then
        os.execute("(/bin/sleep 1; /usr/bin/open '" .. bp .. "') >/dev/null 2>&1 &")
        hs.timer.doAfter(0.6, function() os.exit() end)
      else
        grantReady()
      end
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
  opAdd        = opAdd,
  opEdit       = opEdit,
  opDelete     = opDelete,
  store        = function() return store end,
  exact        = function() return exact end,
  prefixes     = function() return prefixes end,
  catalog      = function() return catalog end,
}
