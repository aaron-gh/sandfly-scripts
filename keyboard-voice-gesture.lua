-- Keyboard voice typing gesture, written for the SandFly Lua script API (version 1).
-- While the keyboard is open, a two-finger double tap presses the keyboard's voice typing key, to
-- start and to stop voice typing. Otherwise the gesture does what it normally does, such as play or
-- pause media, or answer or end a call.
--
-- No "apps" in the manifest on purpose: the script must stay loaded in every app, because the
-- keyboard is a separate window. The script API only searches the app's window, so the voice key is
-- learned from the keyboard's own events (onContentChange and onFocus) and remembered.

local manifest = {
  id = 'keyboard-voice-gesture',
  name = 'Keyboard voice typing gesture',
  version = '1.0.0',
  author = 'Surendra',
  minApiVersion = 1,
  testedApiVersion = 1,
  description = 'While the keyboard is open, a two-finger double tap presses the keyboard voice typing key, to start and to stop voice typing. Otherwise the gesture does what it normally does, such as play or pause media, or answer or end a call.',
  permissions = { 'screen', 'actions', 'speech', 'input' },
  commands = {
    { id = 'voice', title = 'Voice typing', gesture = 'twoFingerDoubleTap' },
  },
}

-- Spoken messages when the gesture runs. Turn on to test.
local DEBUG = false
local function say(text)
  if DEBUG then sf.speak(text) end
end

-- How TalkBack finds the voice key: the keyboard's own window, then the VoiceDictationButton class.
-- The class changes to a plain Button while voice typing runs, so the id comes first.
local VOICE_KEY = {
  { id = 'key_pos_header_power_key' },
  { className = 'VoiceDictationButton' },
  { contentDescription = 'Use voice typing' },
}

-- The custom keyboard and Google's Gboard (including its dev and beta builds).
local function isKeyboard(name)
  return type(name) == 'string' and string.find(name, 'inputmethod.latin', 1, true) ~= nil
end

local key = nil

-- The top item of the window an item is in.
local function top(item)
  local current = item
  for _ = 1, 40 do
    local parent = current:parent()
    if not parent then break end
    current = parent
  end
  return current
end

local function search(from)
  local root = top(from)
  for _, query in ipairs(VOICE_KEY) do
    local found = root:find(query)
    if found and found.visible then return found end
  end
  return nil
end

-- Learns the voice key from any item of the keyboard window.
local function learn(item)
  if not item or not isKeyboard(item.packageName) then return end
  local ok, found = pcall(search, item)
  if ok and found then
    if not key then print('voice key found') end
    key = found
  end
end

-- The remembered key, if it is still on screen. A snapshot that SandFly has dropped raises an
-- error, which counts as "gone".
local function current()
  if not key then return nil end
  local ok, fresh = pcall(function() return key:refresh() end)
  if ok and fresh and fresh.visible then
    key = fresh
    return key
  end
  key = nil
  return nil
end

sf.onContentChange(function(event)
  if not isKeyboard(event.package) or current() then return end
  learn(event.node)
end)

sf.onFocus(function(item)
  if not current() then learn(item) end
end)

-- The time of the last press, so that a command repeated within a second is not pressed twice.
local lastPress = 0

sf.onCommand('voice', function(event)
  local now = os.time()
  if now - lastPress < 1 then
    print('voice command ignored (repeat), via ' .. tostring(event.via))
    return
  end

  local found = current()
  local how = 'remembered key'
  if not found then
    -- The focus can be on the keyboard.
    pcall(learn, event.node)
    found = current()
    how = 'focused item'
  end
  if not found then
    pcall(function() learn(sf.screen.focused()) end)
    found = current()
    how = 'focus of SandFly'
  end
  if not found then
    say('No keyboard')
    -- Keyboard not open: have SandFly do the normal gesture, such as media or calls.
    -- This must be returned before the script waits for anything.
    return false
  end

  lastPress = now
  print('voice command, via ' .. tostring(event.via) .. ', ' .. how)
  say('Voice typing, ' .. how)
  local ok, result = pcall(function() return found:click() end)
  if not ok then
    print('click failed: ' .. tostring(result))
    key = nil
  end
end)

print('voice script ready')
-- SandFly signature: MEQCIHdRxWv2Lise9Ccg4j8cAQUy5+f0x913sIFRguBk1WXjAiBns5aLRYM/qVLuKzd2DM2h461KQGDRknlNaU8dRtSGlA==
