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

ExcelAlt.overlayOn = false
local nAlerts = #mock.log.alerts
tapOption()
typeKeys("hoi")
mock.flushTimers()
check("overlay OFF: action fires but no confirmation alert",
  lastScript():find("autofit entire column") ~= nil and #mock.log.alerts == nAlerts)
ExcelAlt.overlayOn = true

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
print("\n[7] Deferred-UI invariant (guards the v12 fix)")
-- =====================================================================
check("zero canvas/alert/screen calls ever executed inside a tap callback",
  mock.uiViolations == 0, mock.uiViolations)

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
  os.getenv = function(k) if k == "HOME" then return tmp2 end return origGetenv(k) end

  dofile("src/init.lua")
  local T2 = ExcelAlt._test
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
print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
