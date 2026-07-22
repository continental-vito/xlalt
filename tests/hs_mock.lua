-- tests/hs_mock.lua
-- Headless mock of the subset of the Hammerspoon "hs" API that the ⌥XL
-- engine uses. Lets src/init.lua load and run under plain Lua (CI, local
-- dev, this container) with full recorders so tests can assert on
-- AppleScript sent, alerts shown, tap start/stop state, timers, etc.

local M = { log = { osascript = {}, alerts = {}, keystrokes = {}, menuClicks = {} } }

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
    f:close()
    return { mode = "file" }
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
  local names = { "a","b","c","d","e","f","g","h","i","j","k","l","m",
                  "n","o","p","q","r","s","t","u","v","w","x","y","z",
                  "0","1","2","3","4","5","6","7","8","9","=","escape","return","space" }
  for i, n in ipairs(names) do hs.keycodes.map[i] = n end
  M.code = {}
  for i, n in ipairs(names) do M.code[n] = i end
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
    M.log.keystrokes[#M.log.keystrokes + 1] = { mods = mods, key = key }
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
  applicationForPID = function(_) return nil end,
  frontmostApplication = function() return makeApp(M.frontBundle) end,
  watcher = {
    activated = "activated", deactivated = "deactivated",
    terminated = "terminated", launched = "launched", hidden = "hidden",
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

hs.menubar = { new = function()
  local b = { }
  for _, m in ipairs({ "setIcon", "setTitle", "setTooltip", "setMenu" }) do
    b[m] = function(self, v) b["_" .. m] = v ; return self end
  end
  function b:isInMenuBar() return true end
  function b:delete() b.deleted = true end
  M.menubar = b
  return b
end }

hs.image = { imageFromPath = function(_) return nil end }
hs.base64 = { encode = function(s) return "b64" end }
hs.processInfo = { resourcePath = "/tmp/xl-test-resources" }
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

return M
