-- tests/run_tests.lua
-- Headless test suite for the ⌥XL engine. Run with:  lua5.4 tests/run_tests.lua
-- (from the repo root; a temp HOME is created automatically)

-- isolate persistence in a temp HOME
local tmp = os.tmpname() ; os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")
local origGetenv = os.getenv
os.getenv = function(k) if k == "HOME" then return tmp end return origGetenv(k) end

package.path = "tests/?.lua;" .. package.path
local mock = require("hs_mock")
_G.hs = mock.hs

-- load the engine
dofile("src/init.lua")
local T = ExcelAlt._test

-- ------------------------------------------------------------------ harness
local passed, failed = 0, 0
local function check(name, cond, extra)
  if cond then
    passed = passed + 1
    print("  ok    " .. name)
  else
    failed = failed + 1
    print("  FAIL  " .. name .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
  end
end

local function lastScript()
  return mock.log.osascript[#mock.log.osascript] or ""
end

local flagsTap, keyTap = ExcelAlt.flagsTap, ExcelAlt.keyTap

local function tapOption()
  flagsTap.cb(mock.flagsEvent(true))
  flagsTap.cb(mock.flagsEvent(false))
end

local function typeKeys(s)
  local results = {}
  for ch in s:gmatch(".") do
    results[#results + 1] = keyTap.cb(mock.keyEvent(ch))
  end
  return results
end

-- =====================================================================
print("\n[1] Freeze regression: taps run ONLY while Excel is frontmost")
-- =====================================================================
check("taps exist but are NOT enabled at startup (Finder frontmost)",
  not flagsTap:isEnabled() and not keyTap:isEnabled())

mock.activate("com.microsoft.Excel")
check("activating Excel enables both taps",
  flagsTap:isEnabled() and keyTap:isEnabled())

mock.activate("com.apple.Safari")
check("switching to another app disables both taps (keyboard untouched)",
  not flagsTap:isEnabled() and not keyTap:isEnabled())

mock.activate("com.microsoft.Excel")
tapOption()
check("sequence mode entered in Excel", ExcelAlt.mode == true)
mock.activate("com.apple.Safari")
check("leaving Excel mid-sequence exits mode and stops taps",
  ExcelAlt.mode == false and not keyTap:isEnabled())

mock.activate("com.microsoft.Excel")
check("normal typing in Excel (no ⌥ tap) passes through",
  typeKeys("hello")[1] == false)

-- source-level guard: the freeze was caused by a blocking frontmost query
-- inside the tap callbacks. Make sure it never comes back.
do
  local src = io.open("src/init.lua"):read("*a")
  local handlers = src:match("local function handleFlags.-\nend\n") ..
                   src:match("local function handleKey.-\n%-%- An error")
  check("tap callbacks contain no frontmostApplication call",
    not handlers:find("frontmostApplication"))
end

-- =====================================================================
print("\n[2] Error safety: a broken event can never jam the event chain")
-- =====================================================================
do
  local ok, ret = pcall(ExcelAlt.flagsTap.cb, { getFlags = function() error("boom") end })
  check("wrapped flags callback survives an internal error and passes event",
    ok and ret == false)
  local ok2, ret2 = pcall(ExcelAlt.keyTap.cb, setmetatable({}, { __index = function() error("boom") end }))
  check("wrapped key callback survives an internal error and passes event",
    ok2 and ret2 == false)
end

-- =====================================================================
print("\n[3] Sequence engine")
-- =====================================================================
mock.activate("com.microsoft.Excel")
mock.log.osascript = {}

tapOption()
local r = typeKeys("hvv")
mock.flushTimers()  -- action dispatch runs via doAfter
check("H V V is swallowed at every keystroke", r[1] and r[2] and r[3])
check("H V V runs paste-values AppleScript",
  lastScript():find("paste special selection what paste values") ~= nil, lastScript())
check("sequence mode exits after a hit", ExcelAlt.mode == false)

mock.lastCanvas = nil
tapOption()
typeKeys("h")
check("⌥ tap + prefix build NO UI inside the callbacks (v12 freeze fix)",
  mock.lastCanvas == nil)
mock.flushTimers(0)   -- run only the deferred UI tick
check("prefix keeps mode alive; overlay renders on the next tick",
  ExcelAlt.mode and mock.lastCanvas ~= nil and mock.lastCanvas.visible)

typeKeys("q")
mock.flushTimers(0)
check("unknown sequence exits with alert", ExcelAlt.mode == false and
  (mock.log.alerts[#mock.log.alerts] or ""):find("No shortcut") ~= nil)

tapOption()
local esc = keyTap.cb(mock.keyEvent("escape"))
check("Esc cancels and is swallowed", esc == true and ExcelAlt.mode == false)

tapOption()
tapOption()
check("second ⌥ tap cancels the sequence", ExcelAlt.mode == false)

-- ⌥ held as a modifier combo must pass through untouched
flagsTap.cb(mock.flagsEvent(true))          -- option goes down
local combo = keyTap.cb(mock.keyEvent("e")) -- ⌥E typed while held
flagsTap.cb(mock.flagsEvent(false))         -- option released
check("⌥+key combo passes through and does not enter mode",
  combo == false and ExcelAlt.mode == false)

tapOption()
typeKeys("hoi")
mock.flushTimers()
check("H O I autofits column",
  lastScript():find("autofit entire column of selection") ~= nil, lastScript())

tapOption()
typeKeys("hea")
mock.flushTimers()
local mc = mock.log.menuClicks[#mock.log.menuClicks]
check("H E A clicks Edit > Clear > All (user-verified Mac menu path)",
  mc and mc.path[1] == "Edit" and mc.path[2] == "Clear" and mc.path[3] == "All",
  mc and table.concat(mc.path, " > "))

tapOption()
typeKeys("wff")
mock.flushTimers()
check("W F F toggles freeze panes via AppleScript, not menu paths",
  lastScript():find("freeze panes of active window") ~= nil, lastScript())

tapOption()
r = typeKeys("=")
mock.flushTimers()
local ks = mock.log.keystrokes[#mock.log.keystrokes]
check("⌥ = sends AutoSum keystroke",
  r[1] == true and ks and ks.key == "t")

check("sequence timeout timer clears mode", (function()
  tapOption()
  mock.flushTimers()   -- fire the pending timeout
  return ExcelAlt.mode == false
end)())

-- =====================================================================
print("\n[4] Decimal-format heuristic (9 canonical cases)")
-- =====================================================================
local cases = {
  { "General",            1, "0.0" },
  { "0",                  1, "0.0" },
  { "0.00",               1, "0.000" },
  { "0.00",              -1, "0.0" },
  { "0.0",               -1, "0" },
  { "#,##0",              1, "#,##0.0" },
  { "$#,##0.00",         -1, "$#,##0.0" },
  { "0.00%",              1, "0.000%" },
  { "0.00%;[Red](0.00%)", -1, "0.0%;[Red](0.0%)" },
}
for _, c in ipairs(cases) do
  local got = T.adjustFormat(c[1], c[2])
  check(string.format("%-22s %+d -> %s", c[1], c[2], c[3]), got == c[3], got)
end

-- =====================================================================
print("\n[5] Permission gating")
-- =====================================================================
ExcelAlt.tapsReady = false
T.updateTaps()
check("no permission -> taps stay off even in Excel", not keyTap:isEnabled())
ExcelAlt.tapsReady = true
T.updateTaps()
check("grant + Excel frontmost -> taps come on", keyTap:isEnabled())

ExcelAlt.enabled = false
T.updateTaps()
check("pausing from the menu stops taps", not keyTap:isEnabled())
ExcelAlt.enabled = true
T.updateTaps()

-- =====================================================================
print("\n[6] Shortcut store: add / disable / restore, JSON round-trip")
-- =====================================================================
T.opAdd({ seq = "hzz", desc = "Test macro", kind = "keystroke", param = "cmd+shift+z" })
check("custom shortcut registered", T.exact()["hzz"] ~= nil)

tapOption()
typeKeys("hzz")
mock.flushTimers()
ks = mock.log.keystrokes[#mock.log.keystrokes]
check("custom keystroke fires with parsed mods+key",
  ks and ks.key == "z" and ks.mods[1] == "cmd" and ks.mods[2] == "shift")

T.opDelete("hba")
check("deleting a built-in disables it", T.exact()["hba"] == nil)
T.opAdd({ seq = "hba", desc = "All borders", kind = "applescript", param = "-- restored" })
check("re-adding the same sequence restores it", T.exact()["hba"] ~= nil)

local raw = io.open(tmp .. "/Library/Application Support/ExcelAlt/shortcuts.json"):read("*a")
local decoded = mock.hs.json.decode(raw)
check("store persisted as valid JSON with the custom entry",
  decoded.custom ~= nil and #decoded.custom >= 1)

T.opDelete("hzz")
check("deleting a custom removes it without disabling anything",
  T.exact()["hzz"] == nil and decoded.disabled ~= nil)

-- =====================================================================
print("\n[6b] AZERTY digits + editing")
-- =====================================================================
tapOption()
local rd = typeKeys("h1")           -- mock maps digit keycodes to AZERTY symbols
mock.flushTimers()
ks = mock.log.keystrokes[#mock.log.keystrokes]
check("H 1 fires Bold on an AZERTY layout (digits read by keycode)",
  rd[2] == true and ks and ks.key == "b", ks and ks.key)

T.opEdit({ orig = "hbs", builtin = true, luaKind = false,
  seq = "hbb", desc = "My borders", kind = "applescript", param = "-- mine" })
check("editing a plain built-in shadows it under the new sequence",
  T.exact()["hbs"] == nil and T.exact()["hbb"] ~= nil and
  T.exact()["hbb"].desc == "My borders")

T.opEdit({ orig = "h0", builtin = true, luaKind = true,
  seq = "hdd", desc = "More decimals" })
check("renaming a smart built-in keeps its action under the new sequence",
  T.exact()["h0"] == nil and T.exact()["hdd"] ~= nil)
local foundCmd
for _, row in ipairs(T.catalog()) do
  if row.seq == "hdd" then foundCmd = row.cmd end
end
check("catalog exposes the command behind each shortcut",
  type(foundCmd) == "string" and #foundCmd > 0, foundCmd)

tapOption()
typeKeys("wvg")
mock.flushTimers()
check("W V G toggles gridlines via AppleScript",
  lastScript():find("display gridlines of active window") ~= nil, lastScript())

-- The overlay switch is per host: switching it off for Excel must silence
-- Excel only, and must not disturb the other two.
ExcelAlt.overlayOn.excel = false
local nAlerts = #mock.log.alerts
tapOption()
typeKeys("hoi")
mock.flushTimers()
check("overlay OFF: action fires but no confirmation alert",
  lastScript():find("autofit entire column") ~= nil and #mock.log.alerts == nAlerts)
check("switching the overlay off for one host leaves the others on",
  ExcelAlt.overlayOn.powerpoint ~= false and ExcelAlt.overlayOn.word ~= false)
ExcelAlt.overlayOn.excel = true

-- =====================================================================
print("\n[6c] Feedback")
-- =====================================================================
check("version comes from the app bundle, not a hardcoded string",
  ExcelAlt.version == "9.9", ExcelAlt.version)
do
  local ExcelAltUCC = nil
  -- drive the same code path the webview uses
  local sent = ExcelAlt._test.sendFeedback and true or false
  if ExcelAlt._test.sendFeedback then
    ExcelAlt._test.sendFeedback(5, "Great app", "me@example.com")
    local cmds = mock.log.executed or {}
    local last = cmds[#cmds] or ""
    check("feedback opens a prefilled mail to the feedback address",
      last:find("mailto:vito%.continental@gmail%.com") ~= nil and
      last:find("Rating") ~= nil, last:sub(1, 80))
    check("comment text is URL-encoded into the message body",
      last:find("Great%%20app") ~= nil, last:sub(1, 120))
  else
    check("sendFeedback exposed for testing", false)
  end
end

-- =====================================================================
print("\n[8] Multi-host: PowerPoint and Word")
-- =====================================================================
mock.activate(mock.PPT)
check("activating PowerPoint enables the taps",
  flagsTap:isEnabled() and keyTap:isEnabled() and ExcelAlt.activeApp == "powerpoint",
  ExcelAlt.activeApp)

mock.activate(mock.WORD)
check("activating Word switches the active host",
  keyTap:isEnabled() and ExcelAlt.activeApp == "word", ExcelAlt.activeApp)

mock.activate("com.apple.Safari")
check("an unsupported app clears the active host and stops taps",
  ExcelAlt.activeApp == nil and not keyTap:isEnabled())

-- PowerPoint sequences fire against PowerPoint
mock.activate(mock.PPT)
tapOption()
local rp = typeKeys("hi")
mock.flushTimers()
ks = mock.log.keystrokes[#mock.log.keystrokes]
check("PPT H I sends New Slide to PowerPoint, not Excel",
  rp[2] == true and ks and ks.key == "n" and ks.bundle == mock.PPT,
  ks and (ks.key .. "@" .. tostring(ks.bundle)))

tapOption()
typeKeys("sb")
mock.flushTimers()
ks = mock.log.keystrokes[#mock.log.keystrokes]
check("PPT S B plays from the beginning (cmd+shift+return)",
  ks and ks.key == "return" and ks.mods[1] == "cmd" and ks.mods[2] == "shift")

-- Word sequences fire against Word, and AppleScript targets Word
mock.activate(mock.WORD)
mock.log.osascript = {}
tapOption()
typeKeys("hfg")
mock.flushTimers()
check("Word H F G grows the font via a Word-targeted AppleScript",
  lastScript():find('tell application "Microsoft Word"') ~= nil and
  lastScript():find("font size of font object of selection") ~= nil, lastScript())

tapOption()
typeKeys("hs2")
mock.flushTimers()
ks = mock.log.keystrokes[#mock.log.keystrokes]
check("Word H S 2 applies Heading 2 to Word",
  ks and ks.key == "2" and ks.bundle == mock.WORD, ks and tostring(ks.bundle))

-- Sets are isolated: an Excel-only sequence must not resolve in Word
do
  local nAlerts = #mock.log.alerts
  tapOption()
  typeKeys("wvg")            -- Excel: toggle gridlines. Word: nothing.
  mock.flushTimers()
  check("an Excel-only sequence does not resolve in Word",
    (mock.log.alerts[#mock.log.alerts] or ""):find("No shortcut") ~= nil and
    #mock.log.alerts > nAlerts)
end

check("each host builds its own lookup tables",
  T.exact("excel")["hvv"] ~= nil and T.exact("word")["hvv"] ~= nil and
  T.exact("powerpoint")["hvv"] == nil)

check("the same sequence can mean different things per host",
  T.exact("excel")["h1"].desc == "Bold" and T.exact("word")["hs1"].desc == "Heading 1")

-- Per-host customs live in their own slice
T.opAdd({ app = "word", seq = "hzz", desc = "Word only", kind = "keystroke", param = "cmd+shift+w" })
check("a Word custom appears in Word and nowhere else",
  T.exact("word")["hzz"] ~= nil and T.exact("excel")["hzz"] == nil and
  T.exact("powerpoint")["hzz"] == nil)

do
  local st = T.store()
  check("store keeps one slice per host under apps",
    st.apps ~= nil and st.apps.word ~= nil and st.apps.powerpoint ~= nil and
    #st.apps.word.custom == 1 and #st.apps.powerpoint.custom == 0)
  check("Excel slice is mirrored to the top level for older builds",
    st.custom ~= nil and st.custom == st.apps.excel.custom)
end

T.opDelete("hzz", "word")
check("deleting a Word custom leaves the other hosts untouched",
  T.exact("word")["hzz"] == nil and T.exact("excel")["hvv"] ~= nil)

-- Per-host enable switch
ExcelAlt.appEnabled.word = false
T.updateTaps()
check("switching a host off stops the taps while that host is frontmost",
  not keyTap:isEnabled())
mock.activate(mock.PPT)
check("other hosts keep working when one is switched off", keyTap:isEnabled())
ExcelAlt.appEnabled.word = true

-- Regression: the active host used to be inferred from the event type, so
-- any non-activated event for the host in front cleared it and left the
-- taps down until something else forced an update.
mock.activate(mock.PPT)
check("PowerPoint is active and the taps are up",
  ExcelAlt.activeApp == "powerpoint" and keyTap:isEnabled())
mock.appEvent(mock.PPT, "launched")
check("a launched event for the frontmost host does not knock it out",
  ExcelAlt.activeApp == "powerpoint" and keyTap:isEnabled(), ExcelAlt.activeApp)
mock.appEvent(mock.PPT, "unhidden")
check("an unhidden event for the frontmost host does not knock it out",
  ExcelAlt.activeApp == "powerpoint" and keyTap:isEnabled(), ExcelAlt.activeApp)
mock.appEvent(mock.WORD, "terminated")
check("another host quitting elsewhere does not disturb the front one",
  ExcelAlt.activeApp == "powerpoint" and keyTap:isEnabled(), ExcelAlt.activeApp)
mock.flushTimers()
check("the follow-up settle pass agrees with the front app",
  ExcelAlt.activeApp == "powerpoint" and keyTap:isEnabled(), ExcelAlt.activeApp)

-- Switching straight between two hosts must not leave the taps down
mock.activate(mock.WORD)
check("host-to-host switch keeps the taps up and retargets",
  ExcelAlt.activeApp == "word" and keyTap:isEnabled())

-- The manager window is not a host: focusing it stops the taps, and
-- returning to a host brings them back without touching any switch.
mock.activate("com.corgianalyst.excel-alt-shortcuts")
check("focusing the manager stops the taps",
  ExcelAlt.activeApp == nil and not keyTap:isEnabled())
T.web({ op = "appenabled", app = "powerpoint", on = false })
mock.activate(mock.WORD)
check("switching one host off leaves the others working, no toggling needed",
  ExcelAlt.activeApp == "word" and keyTap:isEnabled() and
  ExcelAlt.appEnabled.word ~= false)
mock.activate(mock.PPT)
check("the host that was switched off stays off",
  ExcelAlt.activeApp == "powerpoint" and not keyTap:isEnabled())
T.web({ op = "appenabled", app = "powerpoint", on = true })
check("switching it back on restores it immediately, in place",
  keyTap:isEnabled())

-- The overlay switch is per host end to end, through the manager bridge
T.web({ op = "overlay", app = "powerpoint", on = false })
check("switching the overlay off for one host leaves the others untouched",
  ExcelAlt.overlayOn.powerpoint == false and
  ExcelAlt.overlayOn.excel ~= false and ExcelAlt.overlayOn.word ~= false)
T.web({ op = "overlay", app = "powerpoint", on = true })

check("PowerPoint bundle id is matched case-insensitively",
  T.byBundle["com.microsoft.powerpoint"] == "powerpoint" and
  T.byBundle["com.microsoft.word"] == "word")

-- Built-in hygiene: menu paths would break on a non-English macOS, and a
-- duplicate sequence inside one host would shadow the earlier entry.
for _, a in ipairs(T.apps) do
  local seen, dupe, menus = {}, nil, 0
  for _, b in ipairs(T.builtins[a.id] or {}) do
    if seen[b.seq] then dupe = b.seq end
    seen[b.seq] = true
    if b.kind == "menu" then menus = menus + 1 end
  end
  check(a.label .. ": no duplicate built-in sequences", dupe == nil, dupe)
  if a.id ~= "excel" then
    check(a.label .. ": no menu-path built-ins (localisation safe)", menus == 0, menus)
  end
end

-- =====================================================================
print("\n[12] A fault must never latch the keyboard shut")
-- =====================================================================
-- While ExcelAlt.mode is true every keystroke is swallowed. Anything that
-- throws while mode is on therefore reaches the user as a dead keyboard,
-- which is the worst failure this app can have.
mock.activate(mock.EXCEL)
do
  local boom = T.safely(function() error("simulated fault") end)
  ExcelAlt.mode, ExcelAlt.seq = true, "hv"
  local swallowed = boom({})
  check("a throwing handler does not swallow the key", swallowed == false)
  check("a throwing handler clears sequence mode",
    ExcelAlt.mode == false and ExcelAlt.seq == "")
end

-- The same guarantee when the overlay itself is what fails: that path
-- runs on a timer, outside the tap's pcall.
do
  local realCanvas = mock.hs.canvas.new
  mock.hs.canvas.new = function() error("simulated canvas failure") end
  tapOption()
  typeKeys("h")                 -- a prefix: stays in mode, asks to draw
  mock.flushTimers()
  check("a failed overlay draw does not leave the user in sequence mode",
    ExcelAlt.mode == false, tostring(ExcelAlt.mode))
  mock.hs.canvas.new = realCanvas
end

-- And an old single-boolean overlay preference must not throw when the
-- per-host lookup indexes it.
do
  ExcelAlt.overlayOn = true          -- as an ancient prefs.json would leave it
  tapOption()
  typeKeys("h")
  mock.flushTimers(0.1)   -- the redraw, but not the 4s sequence timeout
  check("a legacy boolean overlay preference is repaired, not fatal",
    type(ExcelAlt.overlayOn) == "table" and ExcelAlt.overlayOn.excel == true)
  ExcelAlt.mode, ExcelAlt.seq = false, ""
end

-- =====================================================================
print("\n[13] The overlay switch is obeyed exactly")
-- =====================================================================
mock.activate(mock.EXCEL)
do
  -- Off means nothing is drawn at all.
  ExcelAlt.overlayOn.excel = false
  ExcelAlt.mode, ExcelAlt.seq = false, ""
  mock.lastCanvas = nil
  tapOption()
  typeKeys("h")
  mock.flushTimers(0.1)
  check("overlay off draws nothing", mock.lastCanvas == nil)
  check("...but shortcuts still work with it off", (function()
    ExcelAlt.mode, ExcelAlt.seq = false, ""
    mock.log.osascript = {}
    tapOption() ; typeKeys("hoi") ; mock.flushTimers()
    return lastScript():find("autofit entire column") ~= nil
  end)())

  -- On draws the full panel with the hint list.
  ExcelAlt.overlayOn.excel = true
  ExcelAlt.mode, ExcelAlt.seq = false, ""
  mock.lastCanvas = nil
  tapOption()
  typeKeys("h")
  mock.flushTimers(0.1)
  check("overlay on draws the full panel with hints",
    mock.lastCanvas ~= nil and mock.lastCanvas.frame.w == 340 and
    #mock.lastCanvas.elements > 4, mock.lastCanvas and #mock.lastCanvas.elements)

  -- Turning one host off leaves the others drawing.
  ExcelAlt.overlayOn.excel = false
  mock.activate(mock.PPT)
  ExcelAlt.mode, ExcelAlt.seq = false, ""
  mock.lastCanvas = nil
  tapOption()
  typeKeys("h")
  mock.flushTimers(0.1)
  check("switching one host's overlay off does not silence the others",
    mock.lastCanvas ~= nil)
  ExcelAlt.overlayOn.excel = true
  mock.activate(mock.EXCEL)
  ExcelAlt.mode, ExcelAlt.seq = false, ""
end

-- The redraw used to sit behind a boolean latch cleared by an unretained
-- timer. If that timer was collected before firing, the latch stayed set
-- and the panel never drew again — while sequences, actions and the
-- confirmation alert all kept working, because none of them go through
-- scheduleUI.
do
  ExcelAlt.overlayOn.excel = true
  mock.activate(mock.EXCEL)
  for i = 1, 5 do
    ExcelAlt.mode, ExcelAlt.seq = false, ""
    mock.lastCanvas = nil
    tapOption()
    typeKeys("h")
    mock.flushTimers(0.1)
    if mock.lastCanvas == nil then break end
  end
  check("the panel still draws after repeated sequences",
    mock.lastCanvas ~= nil and mock.lastCanvas.frame.w == 340)
  ExcelAlt.mode, ExcelAlt.seq = false, ""
end

-- =====================================================================
print("\n[7] Deferred-UI invariant (guards the v12 fix)")
-- =====================================================================
check("zero canvas/alert/screen calls ever executed inside a tap callback",
  mock.uiViolations == 0, mock.uiViolations)

check("firing a shortcut is recorded in debug.log", (function()
  local f = io.open(tmp .. "/Library/Application Support/ExcelAlt/debug.log", "r")
  if not f then return false end
  local log = f:read("*a") ; f:close()
  return log:find("fired %[word%]") ~= nil or log:find("fired %[powerpoint%]") ~= nil
end)())

check("release builds store their data in ExcelAlt/, not a dev directory",
  T.isDev == false and T.support:find("ExcelAlt%-dev") == nil, T.support)

-- =====================================================================
print("\n[11] In-app updates: check, download, install")
-- =====================================================================
local FEED = [[<?xml version="1.0"?><rss><channel><item>
<sparkle:shortVersionString>3.9</sparkle:shortVersionString>
<enclosure url="https://example.test/ExcelAlt-update.zip" length="1234"
 sparkle:edSignature="sig"/>
</item></channel></rss>]]

check("the runtime's own Sparkle check is switched off at startup",
  mock.log.autoUpdateChecks == false, tostring(mock.log.autoUpdateChecks))

check("versions compare numerically, not as strings",
  T.isNewer("3.10", "3.9") and T.isNewer("3.9", "3.8") and
  not T.isNewer("3.9", "3.9") and not T.isNewer("3.9", "3.10") and
  not T.isNewer("3.3", "3.3-dev.branch.abc1234"))

do
  local info = T.appcastInfo(FEED)
  check("the appcast yields version, archive and length",
    info.version == "3.9" and info.url:find("ExcelAlt%-update%.zip") and info.length == 1234)
  check("a malformed appcast yields nothing", T.appcastInfo("<rss/>") == nil)
end

ExcelAlt.version = "3.3"
mock.httpResponse = { 200, FEED }
mock.plistFor = { ["/tmp/xlalt-update/new/ExcelAlt.app/Contents/Info.plist"] =
  { CFBundleShortVersionString = "3.9" } }

-- Declining leaves everything alone.
mock.dialogAnswer = "Later"
mock.log.tasks = {}
T.checkForUpdates(true) ; mock.flushTimers(0.1)
check("offering the update asks before doing anything",
  #mock.log.dialogs > 0 and (mock.log.dialogs[#mock.log.dialogs].msg):find("3.9") ~= nil)
check("declining downloads nothing", #mock.log.tasks == 0)

-- Accepting downloads with curl, unpacks, and hands over to the script.
mock.dialogAnswer = "Install"
mock.log.tasks = {} ; mock.log.executed = {}
ExcelAlt.updating = false
mock.taskResult = { ["/usr/bin/curl"] = { code = 0, before = function()
  local f = io.open("/tmp/xlalt-update/update.zip", "w") ; f:write(string.rep("x", 1234)) ; f:close()
end } }
os.execute("mkdir -p /tmp/xlalt-update")
T.checkForUpdates(true) ; mock.flushTimers(0.1)
do
  local bins = {}
  for _, t in ipairs(mock.log.tasks) do bins[#bins + 1] = t.bin end
  check("the archive is fetched with curl, not the browser",
    bins[1] == "/usr/bin/curl", table.concat(bins, ","))
  check("curl is pointed at the appcast's archive URL",
    table.concat(mock.log.tasks[1].args, " "):find("ExcelAlt%-update%.zip") ~= nil)
  check("the archive is unpacked with ditto", bins[2] == "/usr/bin/ditto")
end
check("the swap is handed to a detached script",
  (table.concat(mock.log.executed, " ")):find("nohup /bin/sh") ~= nil,
  table.concat(mock.log.executed, " "))

do
  local f = io.open("/tmp/xlalt-update/swap.sh")
  local sh = f and f:read("*a") or ""
  if f then f:close() end
  check("the script waits for this process before touching the bundle",
    sh:find("kill %-0") ~= nil and sh:find("ditto") ~= nil)
  check("the script rolls back rather than leaving no app",
    sh:find('mv "%$DEST.old" "%$DEST"') ~= nil)
  check("the script clears quarantine and relaunches",
    sh:find("com.apple.quarantine") ~= nil and sh:find("open") ~= nil)
end

-- A truncated download must never be installed.
ExcelAlt.updating = false
mock.log.tasks = {} ; mock.log.executed = {}
mock.taskResult = { ["/usr/bin/curl"] = { code = 0, before = function()
  local f = io.open("/tmp/xlalt-update/update.zip", "w") ; f:write("short") ; f:close()
end } }
T.checkForUpdates(true) ; mock.flushTimers(0.1)
check("a download of the wrong size is refused",
  (table.concat(mock.log.executed, " ")):find("nohup") == nil)

-- Already current: no dialog, no download.
mock.flushTimers(0.1)   -- let the previous failure's deferred dialog settle
ExcelAlt.version = "3.9"
ExcelAlt.updating = false
mock.log.tasks = {} ; local nD = #mock.log.dialogs
T.checkForUpdates(true) ; mock.flushTimers(0.1)
check("being up to date downloads nothing and asks nothing",
  #mock.log.tasks == 0 and #mock.log.dialogs == nD)
ExcelAlt.version = "3.3" ; mock.httpResponse = nil ; ExcelAlt.updating = false

-- =====================================================================
print("\n[9] Migration from the v1 (Excel-only) shortcuts.json")
-- =====================================================================
-- Reload the engine against a fresh HOME containing a v1 store, and prove
-- the user's existing Excel customs survive the schema change.
do
  local tmp2 = os.tmpname() ; os.remove(tmp2)
  os.execute("mkdir -p '" .. tmp2 .. "/Library/Application Support/ExcelAlt'")
  local f = io.open(tmp2 .. "/Library/Application Support/ExcelAlt/shortcuts.json", "w")
  f:write('{"custom":[{"seq":"hqq","desc":"Legacy macro","kind":"keystroke",' ..
          '"mods":"cmd","key":"9"}],"disabled":{"hba":true},' ..
          '"renames":{"h0":{"seq":"hdd","desc":"More decimals"}}}')
  f:close()
  -- prefs.json from an older build stored overlayOn as a single boolean
  local pf = io.open(tmp2 .. "/Library/Application Support/ExcelAlt/prefs.json", "w")
  pf:write('{"enabled":true,"overlayOn":false}')
  pf:close()
  os.getenv = function(k) if k == "HOME" then return tmp2 end return origGetenv(k) end

  dofile("src/init.lua")
  local T2 = ExcelAlt._test
  check("an old global 'overlay off' is honoured for every host",
    ExcelAlt.overlayOn.excel == false and ExcelAlt.overlayOn.powerpoint == false and
    ExcelAlt.overlayOn.word == false)
  local st = T2.store()
  check("v1 custom shortcut survives the migration",
    T2.exact("excel")["hqq"] ~= nil and st.apps.excel.custom[1].seq == "hqq")
  check("v1 disabled built-in is still disabled",
    st.apps.excel.disabled["hba"] == true and T2.exact("excel")["hba"] == nil)
  check("v1 rename still applies",
    T2.exact("excel")["hdd"] ~= nil and T2.exact("excel")["h0"] == nil)
  check("migrated file gains empty slices for the new hosts",
    st.apps.word ~= nil and st.apps.powerpoint ~= nil and
    #st.apps.word.custom == 0)
  check("version stamp records the new schema", st.version == 2)

  -- writing it back must keep the legacy keys an older build reads
  T2.opAdd({ app = "excel", seq = "hyy", desc = "New", kind = "keystroke", param = "cmd+y" })
  local raw = io.open(tmp2 .. "/Library/Application Support/ExcelAlt/shortcuts.json"):read("*a")
  local back = mock.hs.json.decode(raw)
  check("saved file carries both the v2 slices and the v1 top level",
    back.apps ~= nil and back.apps.excel ~= nil and back.custom ~= nil and
    #back.custom == #back.apps.excel.custom, raw:sub(1, 60))
end

-- =====================================================================
print("\n[10] Development builds are a separate app")
-- =====================================================================
-- A build whose bundle id ends in .dev must keep every byte of its state
-- apart from the released app installed alongside it.
do
  local tmp3 = os.tmpname() ; os.remove(tmp3)
  os.execute("mkdir -p '" .. tmp3 .. "'")
  os.getenv = function(k) if k == "HOME" then return tmp3 end return origGetenv(k) end
  mock.hs.processInfo.bundleID = "com.corgianalyst.excel-alt-shortcuts.dev"

  dofile("src/init.lua")
  local T3 = ExcelAlt._test
  check("a .dev bundle id is detected", T3.isDev == true)
  check("dev builds keep their data in ExcelAlt-dev/",
    T3.support:find("Application Support/ExcelAlt%-dev$") ~= nil, T3.support)

  T3.opAdd({ app = "excel", seq = "hpp", desc = "Dev only", kind = "keystroke", param = "cmd+p" })
  local devFile = io.open(tmp3 .. "/Library/Application Support/ExcelAlt-dev/shortcuts.json", "r")
  check("dev writes land in the dev directory", devFile ~= nil)
  if devFile then devFile:close() end
  local releaseFile = io.open(tmp3 .. "/Library/Application Support/ExcelAlt/shortcuts.json", "r")
  check("dev writes never touch the released app's directory", releaseFile == nil)
  if releaseFile then releaseFile:close() end

  mock.hs.processInfo.bundleID = "com.corgianalyst.excel-alt-shortcuts"
end

-- =====================================================================
print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
