-- tests/hs_mock.lua
-- Headless mock of the subset of the Hammerspoon "hs" API that the ⌥XL
-- engine uses. Lets src/init.lua load and run under plain Lua (CI, local
-- dev, this container) with full recorders so tests can assert on
-- AppleScript sent, alerts shown, tap start/stop state, timers, etc.

local M = { log = { osascript = {}, alerts = {}, keystrokes = {}, menuClicks = {},
                    tasks = {}, dialogs = {}, executed = {}, http = {} } }

-- ------------------------------------------------------------------ json
local json = {}
do
  local function esc(s)
    return s:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
      return map[c] or string.format('\\u%04x', c:byte())
    end)
  end
  local function isArray(t)
    local n = 0
    for k in pairs(t) do
      if type(k) ~= "number" then return false end
      n = n + 1
    end
    return n == #t
  end
  function json.encode(v)
    local t = type(v)
    if v == nil then return "null"
    elseif t == "boolean" or t == "number" then return tostring(v)
    elseif t == "string" then return '"' .. esc(v) .. '"'
    elseif t == "table" then
      local parts = {}
      if isArray(v) then
        for _, x in ipairs(v) do parts[#parts + 1] = json.encode(x) end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        for k, x in pairs(v) do
          parts[#parts + 1] = '"' .. esc(tostring(k)) .. '":' .. json.encode(x)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    end
    error("cannot encode " .. t)
  end

  function json.decode(s)
    local pos = 1
    local function skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local parse
    local function parseString()
      local out, i = {}, pos + 1
      while true do
        local c = s:sub(i, i)
        if c == '"' then pos = i + 1 ; return table.concat(out) end
        if c == "\\" then
          local n = s:sub(i + 1, i + 1)
          local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
          if map[n] then out[#out + 1] = map[n] ; i = i + 2
          elseif n == "u" then
            out[#out + 1] = utf8.char(tonumber(s:sub(i + 2, i + 5), 16)) ; i = i + 6
          else error("bad escape") end
        elseif c == "" then error("unterminated string")
        else out[#out + 1] = c ; i = i + 1 end
      end
    end
    parse = function()
      skip()
      local c = s:sub(pos, pos)
      if c == "{" then
        pos = pos + 1 ; local t = {}
        skip()
        if s:sub(pos, pos) == "}" then pos = pos + 1 ; return t end
        while true do
          skip()
          local k = parseString()
          skip() ; assert(s:sub(pos, pos) == ":") ; pos = pos + 1
          t[k] = parse()
          skip()
          local d = s:sub(pos, pos) ; pos = pos + 1
          if d == "}" then return t end
          assert(d == ",", "expected , or }")
        end
      elseif c == "[" then
        pos = pos + 1 ; local t = {}
        skip()
        if s:sub(pos, pos) == "]" then pos = pos + 1 ; return t end
        while true do
          t[#t + 1] = parse()
          skip()
          local d = s:sub(pos, pos) ; pos = pos + 1
          if d == "]" then return t end
          assert(d == ",", "expected , or ]")
        end
      elseif c == '"' then return parseString()
      elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 ; return true
      elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 ; return false
      elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 ; return nil
      else
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        assert(num, "bad json at " .. pos)
        pos = pos + #num
        return tonumber(num)
      end
    end
    return parse()
  end
end

-- ------------------------------------------------------------------ timers
M.timers = {}
M.inCallback = false      -- true while a tap callback is executing
M.uiViolations = 0        -- window-server calls made inside a callback
local function newTimer(fn, every, delay)
  local t = { fn = fn, every = every, delay = delay or 0, stopped = false }
  function t:stop() self.stopped = true end
  M.timers[#M.timers + 1] = t
  return t
end

-- clearTimers() drops everything pending without running it. Needed
-- because a test that installs an update leaves the engine's 0.4s
-- "quit now" timer queued; a later flushTimers(2) would fire it and end
-- the test process silently, with exit status 0.
function M.clearTimers() M.timers = {} end

-- flushTimers()          runs everything pending
-- flushTimers(maxDelay)  runs only timers scheduled with delay <= maxDelay
function M.flushTimers(maxDelay)
  local pending, keep = M.timers, {}
  M.timers = {}
  for _, t in ipairs(pending) do
    if t.stopped then
      -- drop
    elseif maxDelay ~= nil and t.delay > maxDelay then
      keep[#keep + 1] = t
    else
      t.fn()
      if t.every then keep[#keep + 1] = t end
    end
  end
  for _, t in ipairs(keep) do M.timers[#M.timers + 1] = t end
end

local function uiCall()
  if M.inCallback then M.uiViolations = M.uiViolations + 1 end
end

-- ------------------------------------------------------------------ hs
local hs = {}

hs.json = { encode = function(v, _) return json.encode(v) end, decode = json.decode }

hs.fs = {
  mkdir = function(p) os.execute("mkdir -p '" .. p .. "'") ; return true end,
  attributes = function(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return { mode = "file", size = size }
  end,
  -- Real listing, like mkdir above: the updater has to find the bundle
  -- inside the archive by looking, since its name changes between
  -- releases.
  dir = function(path)
    local names, pipe = {}, io.popen("ls -1 '" .. path .. "' 2>/dev/null")
    if pipe then
      for line in pipe:lines() do names[#names + 1] = line end
      pipe:close()
    end
    local i = 0
    return function() i = i + 1 ; return names[i] end
  end,
}

hs.alert = { show = function(msg, _)
  uiCall()
  M.log.alerts[#M.log.alerts + 1] = tostring(msg)
end }

hs.osascript = {
  result = nil,   -- tests may set M.hs.osascript.result for the next call
  applescript = function(script)
    M.log.osascript[#M.log.osascript + 1] = script
    local r = hs.osascript.result
    hs.osascript.result = nil
    if r ~= nil then return true, r end
    return true, nil
  end,
}

-- keycodes: enough of a map for the tests (code -> name)
hs.keycodes = { map = {} }
do
  M.code = {}
  local letters = { "a","b","c","d","e","f","g","h","i","j","k","l","m",
                    "n","o","p","q","r","s","t","u","v","w","x","y","z",
                    "=","escape","return","space" }
  for i, n in ipairs(letters) do            -- offset avoids real digit codes
    hs.keycodes.map[100 + i] = n
    M.code[n] = 100 + i
  end
  -- digits live at their REAL macOS keycodes (engine reads them raw)
  local digitCodes = { ["1"]=18,["2"]=19,["3"]=20,["4"]=21,["5"]=23,
                       ["6"]=22,["7"]=26,["8"]=28,["9"]=25,["0"]=29 }
  for ch, code in pairs(digitCodes) do
    M.code[ch] = code
    -- deliberately map these to AZERTY symbols to prove layout independence
    hs.keycodes.map[code] = ({["1"]="&",["2"]="é",["3"]='"',["4"]="'",["5"]="(",
                              ["6"]="-",["7"]="è",["8"]="_",["9"]="ç",["0"]="à"})[ch]
  end
end

-- eventtap
hs.eventtap = {
  event = { types = { flagsChanged = "flagsChanged", keyDown = "keyDown" } },
  new = function(types, cb)
    local wrapped = function(e)
      M.inCallback = true
      local ok, r = pcall(cb, e)
      M.inCallback = false
      if not ok then error(r, 0) end
      return r
    end
    local tap = { types = types, cb = wrapped, enabled = false }
    function tap:start() self.enabled = true end
    function tap:stop() self.enabled = false end
    function tap:isEnabled() return self.enabled end
    M.taps = M.taps or {}
    M.taps[#M.taps + 1] = tap
    return tap
  end,
  keyStroke = function(mods, key, delay, app)
    -- the target app is recorded so tests can prove a shortcut was sent to
    -- the host it belongs to, not merely that some keystroke happened
    local bundle = nil
    if type(app) == "table" and app.bundleID then bundle = app.bundleID() end
    M.log.keystrokes[#M.log.keystrokes + 1] = { mods = mods, key = key, bundle = bundle }
  end,
}

-- application + watcher
M.frontBundle = "com.apple.finder"
local function makeApp(bundle)
  return {
    bundleID = function() return bundle end,
    selectMenuItem = function(_, path, regex)
      M.log.menuClicks[#M.log.menuClicks + 1] = { path = path, regex = regex or false }
      return true
    end,
  }
end
M.makeApp = makeApp

hs.application = {
  get = function(bundle) return makeApp(bundle) end,
  -- Our own process, so the engine's Preferences window can be watched
  -- for and replaced with ours.
  applicationForPID = function(_)
    M.selfApp = M.selfApp or {
      newWatcher = function(_, fn)
        M.windowWatcher = { fn = fn, started = false, events = nil }
        return {
          start = function(_, events)
            M.windowWatcher.started = true
            M.windowWatcher.events = events
          end,
        }
      end,
      allWindows = function() return M.appWindows or {} end,
    }
    return M.selfApp
  end,
  frontmostApplication = function() return makeApp(M.frontBundle) end,
  watcher = {
    activated = "activated", deactivated = "deactivated",
    terminated = "terminated", launched = "launched", hidden = "hidden",
    unhidden = "unhidden",
    new = function(fn)
      M.watcherFn = fn
      return { start = function() end, stop = function() end }
    end,
  },
}

-- canvas / screen / menubar / image / webview / misc
hs.screen = { mainScreen = function()
  uiCall()
  return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
end }

hs.canvas = {
  windowLevels = { overlay = 102 },
  new = function(frame)
    uiCall()
    local c = { frame = frame, elements = {}, visible = false }
    function c:appendElements(e) self.elements[#self.elements + 1] = e ; return self end
    function c:level(_) return self end
    function c:show() self.visible = true ; M.lastCanvas = self ; return self end
    function c:delete() self.visible = false end
    return c
  end,
}

-- Menu bar. The interesting states are not "created or not" but what
-- macOS did with the item afterwards, so the frame is configurable:
--   M.menubarFrame = nil                       -- frame() unavailable
--   M.menubarFrame = {x=0,y=956,w=69,h=0}      -- the zero-height failure
--   M.menubarFrame = {x=1200,y=0,w=24,h=24}    -- healthy
-- M.log.menubars records every item ever created, so a test can catch
-- creation churn as well as the end state.
M.menubarFrame = { x = 1200, y = 0, w = 24, h = 24 }
M.log.menubars = {}

hs.menubar = { new = function(inBar, autosaveName)
  local b = { autosaveName = autosaveName, inBar = (inBar ~= false) }
  for _, m in ipairs({ "setIcon", "setTitle", "setTooltip", "setMenu" }) do
    b[m] = function(self, v) b["_" .. m] = v ; return self end
  end
  function b:isInMenuBar() return b.inBar end
  function b:frame()
    if M.menubarFrame == nil then error("no frame") end
    return M.menubarFrame
  end
  function b:removeFromMenuBar() b.inBar = false ; b.removed = true ; return b end
  function b:returnToMenuBar()   b.inBar = true  ; b.returned = true ; return b end
  function b:delete() b.deleted = true end
  M.menubar = b
  table.insert(M.log.menubars, b)
  return b
end }

hs.image = { imageFromPath = function(_) return nil end }
hs.base64 = { encode = function(s) return "b64" end }
hs.uielement = { watcher = { windowCreated = "AXWindowCreated",
                             focusedWindowChanged = "AXFocusedWindowChanged" } }
hs.processInfo = { processID = 4242, resourcePath = "/tmp/xl-test-resources",
                   bundlePath = "/tmp/xl-test-app/ExcelAlt.app",
                   processID = 4242,
                   bundleID = "com.corgianalyst.excel-alt-shortcuts" }
hs.plist = { read = function(path)
  -- Tests can stub a specific path (an update being unpacked, say);
  -- everything else is the running bundle.
  -- An explicit false means "this plist cannot be read", which is not the
  -- same as "no stub for this path".
  if M.plistFor and M.plistFor[path] ~= nil then
    local v = M.plistFor[path]
    if v == false then return nil end
    return v
  end
  return { CFBundleShortVersionString = "9.9" }
end }
-- Tests set M.httpResponse = { status, body } to script the next fetch.
-- The login item, which the engine's own Preferences window used to own.
M.loginItem = false
hs.autoLaunch = function(state)
  if state ~= nil then M.loginItem = state end
  return M.loginItem
end
hs.menuIcon = function(_) return false end
hs.closeConsole = function() end

hs.automaticallyCheckForUpdates = function(on)
  M.log.autoUpdateChecks = on
end

-- The runtime's Sparkle entry point. Tests set M.sparkleBroken to make it
-- fail, which is how the fallback to the built-in downloader is checked.
hs.checkForUpdates = function()
  if M.sparkleBroken then error("sparkle unavailable") end
  M.log.sparkleChecks = (M.log.sparkleChecks or 0) + 1
end

-- Subprocesses: tests script the outcome with M.taskResult[bin] and read
-- back what was actually run.
hs.task = { new = function(bin, done, args)
  local t = { bin = bin, args = args }
  function t:start()
    M.log.tasks[#M.log.tasks + 1] = { bin = bin, args = args }
    local r = M.taskResult and M.taskResult[bin]
    local code = r and r.code or 0
    if r and r.before then r.before() end
    if done then done(code, r and r.out or "", r and r.err or "") end
    return self
  end
  return t
end }

-- Modal dialogs: tests answer with M.dialogAnswer.
hs.dialog = { blockAlert = function(msg, info, b1, b2)
  M.log.dialogs[#M.log.dialogs + 1] = { msg = msg, info = info, buttons = { b1, b2 } }
  return M.dialogAnswer or b1
end }


hs.http = { asyncGet = function(url, _, cb)
  M.log.http = M.log.http or {}
  M.log.http[#M.log.http + 1] = url
  local r = M.httpResponse or { 404, "" }
  if cb then cb(r[1], r[2]) end
end }
hs.host = { operatingSystemVersion = function() return { major = 15, minor = 0, patch = 0 } end }
hs.execute = function(cmd) M.log.executed = M.log.executed or {} ;
  M.log.executed[#M.log.executed + 1] = cmd ; return "", true, "exit", 0 end
-- Real key store: the status-item purge is about which keys survive, so
-- a stub that returns an empty list makes the test vacuous.
M.settings = {}
hs.settings = {
  getKeys = function()
    local out = {}
    for k in pairs(M.settings) do out[#out + 1] = k end
    table.sort(out)
    return out
  end,
  clear = function(k) M.settings[k] = nil end,
  set   = function(k, v) M.settings[k] = v end,
  get   = function(k) return M.settings[k] end,
}
hs.hotkey = { new = function(mods, key, fn)
  return { enable = function() end, disable = function() end }
end }
hs.webview = {
  usercontent = { new = function(_) return { setCallback = function(self, cb) M.webviewCb = cb ; return self end } end },
  new = function() error("webview should not be constructed in headless tests") end,
}

M.accessibility = true
hs.accessibilityState = function(_) return M.accessibility end

hs.timer = {
  doAfter = function(t, fn) return newTimer(fn, false, t) end,
  doEvery = function(t, fn) return newTimer(fn, true, t) end,
}

M.hs = hs

-- Event constructors for tests
function M.flagsEvent(altDown)
  return { getFlags = function() return { alt = altDown } end,
           getKeyCode = function() return 0 end }
end

function M.keyEvent(name)
  local code = M.code[name] or error("unknown key " .. tostring(name))
  return { getFlags = function() return {} end,
           getKeyCode = function() return code end }
end

-- Convenience: simulate app activation events through the engine's watcher
function M.activate(bundle)
  M.frontBundle = bundle
  M.watcherFn("App", "activated", makeApp(bundle))
end

-- Deliver an arbitrary watcher event WITHOUT changing which app is front:
-- used to prove a stray event cannot knock out a host that is still in
-- front of the user.
function M.appEvent(bundle, event)
  M.watcherFn("App", event, makeApp(bundle))
end

-- Bundle ids of the three supported hosts, for readability in tests
M.EXCEL = "com.microsoft.Excel"
M.PPT   = "com.microsoft.Powerpoint"
M.WORD  = "com.microsoft.Word"

return M
