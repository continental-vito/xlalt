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
-- =====================================================================

-- Global state table FIRST (v8 crash fix: never index before init)
ExcelAlt = {
  version    = "1.2",
  enabled    = true,
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
local APPNAME = "⌥XL"
local SEQ_TIMEOUT = 4

-- ---------------------------------------------------------------------
-- Paths & persistence (own Application Support dir, never Hammerspoon's)
-- ---------------------------------------------------------------------
local SUPPORT = os.getenv("HOME") .. "/Library/Application Support/ExcelAlt"
hs.fs.mkdir(SUPPORT)
local STORE = SUPPORT .. "/shortcuts.json"
local PREFS = SUPPORT .. "/prefs.json"

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
-- Built-in shortcut map (Windows Alt sequences)
-- ---------------------------------------------------------------------
local BUILTIN = {
  -- Home: clipboard / editing
  { seq = "hvv", desc = "Paste values",            fn = ascript("paste special selection what paste values") },
  { seq = "hvf", desc = "Paste formulas",          fn = ascript("paste special selection what paste formulas") },
  { seq = "hvt", desc = "Paste formats",           fn = ascript("paste special selection what paste formats") },
  { seq = "es",  desc = "Paste Special…",          fn = stroke({"ctrl","cmd"}, "v") },

  -- Home: font-ish
  { seq = "h1",  desc = "Bold",                    fn = stroke({"cmd"}, "b") },
  { seq = "h2",  desc = "Italic",                  fn = stroke({"cmd"}, "i") },
  { seq = "h3",  desc = "Underline",               fn = stroke({"cmd"}, "u") },

  -- Home: alignment
  { seq = "hac", desc = "Align center",            fn = ascript("set horizontal alignment of selection to horizontal align center") },
  { seq = "hal", desc = "Align left",              fn = ascript("set horizontal alignment of selection to horizontal align left") },
  { seq = "har", desc = "Align right",             fn = ascript("set horizontal alignment of selection to horizontal align right") },
  { seq = "hat", desc = "Align top",               fn = ascript("set vertical alignment of selection to vertical alignment top") },
  { seq = "ham", desc = "Align middle",            fn = ascript("set vertical alignment of selection to vertical alignment center") },
  { seq = "hab", desc = "Align bottom",            fn = ascript("set vertical alignment of selection to vertical alignment bottom") },
  { seq = "hw",  desc = "Wrap text (toggle)",      fn = ascript("set wrap text of selection to not (wrap text of selection)") },
  { seq = "hmc", desc = "Merge & center",          fn = ascript("merge selection\nset horizontal alignment of selection to horizontal align center") },
  { seq = "hmu", desc = "Unmerge cells",           fn = ascript("unmerge selection") },

  -- Home: number formats
  { seq = "h0",  desc = "Increase decimals",       fn = decimals(1) },
  { seq = "h9",  desc = "Decrease decimals",       fn = decimals(-1) },
  { seq = "hp",  desc = "Percent style",           fn = setFormat("0%") },
  { seq = "hk",  desc = "Comma style",             fn = setFormat("#,##0.00") },
  { seq = "han", desc = "Accounting format",       fn = setFormat("_($* #,##0.00_);_($* (#,##0.00);_($* \\\"-\\\"??_);_(@_)") },

  -- Home: borders (Windows letters O/P/L/R/N/A/S/T)
  { seq = "hbo", desc = "Bottom border",           fn = border("edge bottom") },
  { seq = "hbp", desc = "Top border",              fn = border("edge top") },
  { seq = "hbl", desc = "Left border",             fn = border("edge left") },
  { seq = "hbr", desc = "Right border",            fn = border("edge right") },
  { seq = "hbn", desc = "No borders",              fn = noBorders() },
  { seq = "hba", desc = "All borders",             fn = allBorders("edge bottom, edge top, edge left, edge right, inside horizontal, inside vertical") },
  { seq = "hbs", desc = "Outside borders",         fn = allBorders("edge bottom, edge top, edge left, edge right") },
  { seq = "hbt", desc = "Thick box border",        fn = allBorders("edge bottom, edge top, edge left, edge right", "border weight thick") },

  -- Home: cells / rows / columns
  { seq = "hoi", desc = "AutoFit column width",    fn = ascript("autofit entire column of selection") },
  { seq = "hoa", desc = "AutoFit row height",      fn = ascript("autofit entire row of selection") },
  { seq = "how", desc = "Column width…",           fn = menu({"Format", "Column", "Width..."}) },
  { seq = "hoh", desc = "Row height…",             fn = menu({"Format", "Row", "Height..."}) },
  { seq = "hir", desc = "Insert row",              fn = ascript("insert into range (entire row of selection) shift shift down") },
  { seq = "hic", desc = "Insert column",           fn = ascript("insert into range (entire column of selection) shift shift to right") },
  { seq = "hdr", desc = "Delete row",              fn = ascript("delete range (entire row of selection) shift shift up") },
  { seq = "hdc", desc = "Delete column",           fn = ascript("delete range (entire column of selection) shift shift to left") },

  -- Formulas
  { seq = "=",   desc = "AutoSum",                 fn = stroke({"cmd","shift"}, "t") },

  -- Data
  { seq = "asa", desc = "Sort ascending",          fn = ascript("sort selection key1 active cell order1 sort ascending") },
  { seq = "asd", desc = "Sort descending",         fn = ascript("sort selection key1 active cell order1 sort descending") },
  { seq = "att", desc = "Toggle AutoFilter",       fn = ascript("set autofilter mode of active sheet to not (autofilter mode of active sheet)") },
  { seq = "agg", desc = "Group rows/columns",      fn = ascript("group entire row of selection") },
  { seq = "agu", desc = "Ungroup",                 fn = ascript("ungroup entire row of selection") },

  -- View / Window
  { seq = "wff", desc = "Freeze panes (toggle)",   fn = menu({"Window", "Freeze Panes"}) },
  { seq = "wfu", desc = "Unfreeze panes",          fn = menu({"Window", "Unfreeze Panes"}) },
}

-- ---------------------------------------------------------------------
-- Custom shortcuts + disabled built-ins (manager persistence)
-- ---------------------------------------------------------------------
local store = readJSON(STORE) or { custom = {}, disabled = {} }
store.custom, store.disabled = store.custom or {}, store.disabled or {}

local function customFn(entry)
  if entry.kind == "keystroke" then
    local mods = {}
    for m in (entry.mods or ""):gmatch("[^+]+") do mods[#mods + 1] = m end
    return stroke(mods, entry.key or "")
  elseif entry.kind == "menu" then
    local path = {}
    for part in (entry.path or ""):gmatch("[^>]+") do
      path[#path + 1] = part:match("^%s*(.-)%s*$")
    end
    return menu(path)
  else
    return ascript(entry.script or "")
  end
end

local exact, prefixes, catalog = {}, {}, {}

local function rebuild()
  exact, prefixes, catalog = {}, {}, {}
  local function add(seq, desc, fn, builtin)
    exact[seq] = { desc = desc, fn = fn }
    for i = 1, #seq - 1 do prefixes[seq:sub(1, i)] = true end
    catalog[#catalog + 1] = { seq = seq, desc = desc, builtin = builtin }
  end
  for _, s in ipairs(BUILTIN) do
    if not store.disabled[s.seq] then add(s.seq, s.desc, s.fn, true) end
  end
  for _, c in ipairs(store.custom) do
    if c.seq and #c.seq > 0 then add(c.seq:lower(), c.desc or "Custom", customFn(c), false) end
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

  local key = hs.keycodes.map[e:getKeyCode()]
  if key == "escape" then exitMode() ; return true end
  if type(key) ~= "string" or #key ~= 1 then exitMode() ; return false end

  ExcelAlt.seq = ExcelAlt.seq .. key:lower()
  if ExcelAlt.timeout then ExcelAlt.timeout:stop() end
  ExcelAlt.timeout = hs.timer.doAfter(SEQ_TIMEOUT, exitMode)

  local hit = exact[ExcelAlt.seq]
  if hit then
    exitMode()
    say(hit.desc, 0.8)
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
  local isExcel = app ~= nil and app:bundleID() == EXCEL
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
  padding:18px 24px; display:flex; align-items:center; gap:14px; }
header img { width:44px; height:44px; border-radius:10px; }
header h1 { font-size:19px; font-weight:700; letter-spacing:.2px; }
header p { font-size:12px; opacity:.85; margin-top:2px; }
main { padding:20px 24px; max-width:760px; margin:0 auto; }
table { width:100%; border-collapse:collapse; background:#fff; border-radius:10px; overflow:hidden;
  box-shadow:0 1px 4px rgba(0,0,0,.08); }
th { text-align:left; font-size:11px; text-transform:uppercase; letter-spacing:.8px;
  color:#6b7570; padding:10px 14px; border-bottom:1px solid #e6e3da; }
td { padding:9px 14px; font-size:13px; border-bottom:1px solid #f0ede5; }
td.seq { font-family:'SF Mono',Menlo,monospace; font-weight:700; color:var(--green);
  white-space:nowrap; }
td.seq::before { content:'⌥ '; color:var(--gold); }
tr:hover td { background:#fbfaf6; }
.tag { font-size:10px; padding:2px 7px; border-radius:99px; background:#eef3ee; color:#4c6355; }
.tag.custom { background:#fdf3d5; color:#8a6a12; }
button { border:0; border-radius:7px; padding:6px 12px; font-size:12px; cursor:pointer; }
button.del { background:transparent; color:#b04a3a; }
button.del:hover { background:#f9e9e6; }
.addbar { display:flex; gap:8px; margin:18px 0 10px; flex-wrap:wrap; }
.addbar input, .addbar select { padding:8px 10px; border:1px solid #d8d4c8; border-radius:7px;
  font-size:13px; background:#fff; }
#f-seq { width:80px; font-family:'SF Mono',Menlo,monospace; }
#f-desc { flex:1; min-width:140px; }
#f-param { flex:2; min-width:200px; }
.addbar .go { background:var(--green); color:#fff; font-weight:600; }
.addbar .go:hover { background:var(--green2); }
.hint { font-size:11.5px; color:#8a877d; margin-bottom:6px; }
</style></head><body>
<header>
  <img src="CORGI_SRC" alt="">
  <div><h1>⌥XL Shortcut Manager</h1>
    <p>Tap ⌥ in Excel, then type a sequence. Changes apply instantly.</p></div>
</header>
<main>
  <div class="addbar">
    <input id="f-seq" placeholder="hxx" maxlength="6">
    <input id="f-desc" placeholder="What it does">
    <select id="f-kind">
      <option value="keystroke">Keystroke</option>
      <option value="menu">Menu path</option>
      <option value="applescript">AppleScript</option>
    </select>
    <input id="f-param" placeholder="cmd+shift+t   ·   Format > Cells...   ·   script body">
    <button class="go" onclick="add()">Add shortcut</button>
  </div>
  <p class="hint">Keystroke: mods+key like <b>cmd+shift+t</b> · Menu: path like <b>Format > Column > Width...</b> · AppleScript: body runs inside a tell-Excel block. Deleting a built-in hides it; it can be restored by re-adding the same sequence.</p>
  <table><thead><tr><th>Sequence</th><th>Action</th><th></th><th></th></tr></thead>
  <tbody id="rows"></tbody></table>
</main>
<script>
function render(list) {
  const tb = document.getElementById('rows'); tb.innerHTML = '';
  list.forEach(it => {
    const tr = document.createElement('tr');
    tr.innerHTML = '<td class="seq">' + it.seq.toUpperCase().split('').join(' ') + '</td>' +
      '<td>' + it.desc + '</td>' +
      '<td><span class="tag' + (it.builtin ? '' : ' custom') + '">' +
      (it.builtin ? 'built-in' : 'custom') + '</span></td>' +
      '<td style="text-align:right"><button class="del" onclick="del(\'' + it.seq + '\')">Remove</button></td>';
    tb.appendChild(tr);
  });
}
function send(msg) { window.webkit.messageHandlers.xl.postMessage(msg); }
function del(seq) { send({ op: 'delete', seq: seq }); }
function add() {
  const seq = document.getElementById('f-seq').value.trim().toLowerCase();
  const desc = document.getElementById('f-desc').value.trim();
  const kind = document.getElementById('f-kind').value;
  const param = document.getElementById('f-param').value.trim();
  if (!seq || !param) return;
  send({ op: 'add', seq: seq, desc: desc || 'Custom', kind: kind, param: param });
  ['f-seq','f-desc','f-param'].forEach(id => document.getElementById(id).value = '');
}
send({ op: 'load' });
</script></body></html>
]==]

local function pushCatalog()
  if not ExcelAlt.manager then return end
  ExcelAlt.manager:evaluateJavaScript("render(" .. hs.json.encode(catalog) .. ")")
end

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

local function opAdd(b)
  store.disabled[b.seq] = nil
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
  local kept = {}
  for _, c in ipairs(store.custom) do
    if c.seq:lower() ~= b.seq then kept[#kept + 1] = c end
  end
  kept[#kept + 1] = entry
  store.custom = kept
  saveStore()
end

local function openManager()
  if ExcelAlt.manager then
    ExcelAlt.manager:show() ; ExcelAlt.manager:bringToFront(true)
    pushCatalog()
    return
  end
  ExcelAlt.ucc = hs.webview.usercontent.new("xl"):setCallback(function(msg)
    local b = msg.body
    if b.op == "load" then pushCatalog()
    elseif b.op == "delete" then opDelete(b.seq)
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
    :windowStyle({ "titled", "closable", "resizable" })
    :windowTitle(APPNAME .. " Shortcut Manager")
    :allowTextEntry(true)
    :deleteOnClose(false)
    :html(html)
  ExcelAlt.manager:show()
  ExcelAlt.manager:bringToFront(true)
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
        writeJSON(PREFS, { enabled = ExcelAlt.enabled })
        updateTaps()
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
  ExcelAlt.bar = hs.menubar.new()
  if not ExcelAlt.bar then return end
  local p = hs.processInfo.resourcePath .. "/xl-menubar@2x.png"
  if fileExists(p) then
    local img = hs.image.imageFromPath(p)
    if img then
      img = img:setSize({ w = 18, h = 18 })
      img = img:template(true)
      ExcelAlt.barIcon = img
      ExcelAlt.bar:setIcon(img)
    end
  end
  if not ExcelAlt.barIcon then ExcelAlt.bar:setTitle("⌥XL") end
  ExcelAlt.bar:setTooltip(APPNAME .. " — Alt shortcuts for Excel")
  ExcelAlt.bar:setMenu(menubarMenu)
end

-- ---------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------
local prefs = readJSON(PREFS)
if prefs and prefs.enabled == false then ExcelAlt.enabled = false end

ExcelAlt.flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, safely(handleFlags))
ExcelAlt.keyTap   = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, safely(handleKey))

-- One-time frontmost check at startup (allowed here: not inside a tap)
do
  local f = hs.application.frontmostApplication()
  ExcelAlt.excelFront = f ~= nil and f:bundleID() == EXCEL
end

ExcelAlt.watcher = hs.application.watcher.new(onAppEvent)
ExcelAlt.watcher:start()

setupMenubar()

local function grantReady()
  ExcelAlt.tapsReady = true
  updateTaps()
  hs.alert.show(APPNAME .. " ready — tap ⌥ in Excel", 1.5)
end

if hs.accessibilityState(true) then
  grantReady()
else
  hs.alert.show(APPNAME .. " needs Accessibility permission\n(System Settings → Privacy & Security)", 4)
  -- Taps opened before permission never attach; poll and start once granted
  ExcelAlt.permTimer = hs.timer.doEvery(2, function()
    if hs.accessibilityState() then
      ExcelAlt.permTimer:stop()
      ExcelAlt.permTimer = nil
      grantReady()
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
  opDelete     = opDelete,
  store        = function() return store end,
  exact        = function() return exact end,
  prefixes     = function() return prefixes end,
  catalog      = function() return catalog end,
}
