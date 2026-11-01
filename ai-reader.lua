-- AI reader: says an AI app's reply once the app has finished writing it.
--
-- This is the Backtalk script of the same name (JavaScript) ported to SandFly's
-- Lua scripting API. It is a port of Waypoint, an accessibility service.
--
-- The per-app rules below are Waypoint's measured rules, kept as they were:
-- Gemini's view ids and Claude's "Copy message" row. Each is an
-- implementation detail of that app and may break in a future
-- release. The Log on this script's page says what it pulled out of the
-- screen, so a break can be told apart from a quiet conversation.

local manifest = {
  id = 'ai-reader',
  name = 'AI reader',
  version = '1.13',
  author = 'Devin Prater',
  minApiVersion = 1,
  testedApiVersion = 1,
  description = 'Says a reply when an AI app finishes writing it, including any code blocks. A port of Waypoint.',
  apps = {
    'com.google.android.googlequicksearchbox',
    'com.anthropic.claude',
  },
  permissions = { 'screen', 'speech' },
  settings = {
    {
      key = 'starting',
      type = 'switch',
      title = 'Say Generating when a reply starts',
      default = true,
    },
    {
      key = 'quiet',
      type = 'number',
      title = 'Seconds of quiet before reading a reply',
      summary = 'A reply is read once the screen has stopped changing for this long. 1 to 10.',
      default = 3,
    },
    {
      key = 'code',
      type = 'switch',
      title = 'Say Code block around code',
      default = true,
    },
    {
      key = 'interrupt',
      type = 'switch',
      title = 'Cut off other speech to read a reply',
      default = false,
    },
  },
}

local GEMINI = 'com.google.android.googlequicksearchbox'
local CLAUDE = 'com.anthropic.claude'
local APPS = { [GEMINI] = true, [CLAUDE] = true }
local NAMES = { [GEMINI] = 'Gemini', [CLAUDE] = 'Claude' }

local tr = sf._

local CODE_START = 'Code block:'
local CODE_END = 'Code block end.'

local CHECK_DELAY_MS = 250 -- The screen changes in bursts; look once a burst.
local POLL_MS = 2500 -- Some apps send no content changes while a reply streams.
local MAX_POLLS = 60 -- Two and a half minutes of quiet before polling stops.
local RETRY_MS = 1000 -- A reply can pause; look again this much later.
local MAX_RETRIES = 15 -- Give up on one stream after this many pauses.
local MAX_ERRORS_LOGGED = 3
local BASELINE_MS = 1500 -- How long the reply on screen counts as already read.

local pendingText = '' -- The newest reply we have seen on screen.
local spokenText = '' -- The last reply we read out.
local generation = 0 -- Counts each time an app starts writing a new reply.
local pendingGeneration = 0 -- The generation that `pendingText` came from.
local spokenGeneration = 0 -- The generation that `spokenText` came from.
local generating = false
local baselined = false -- Whether we have noted the reply already on screen.
local baselineDue = false -- Set when the baseline wait is over.
local baselineTimer = nil
local scheduled = nil
local quiet = nil
local poll = nil
local retries = 0
local errorsLogged = 0
local changes = 0
local polls = 0

-- Forward declarations, since these call each other.
local check, finish, schedule, reset, codeBlock

-- ---------------------------------------------------------------------------
-- Helpers over SandFly's items.
-- ---------------------------------------------------------------------------

local function clean(value)
  if value == nil then
    return ''
  end
  local text = tostring(value):gsub('[\t ]+', ' ')
  return text:match('^%s*(.-)%s*$') or ''
end

local function descOf(item)
  return clean(item.contentDescription)
end

local function idOf(item)
  if item.id == nil then
    return ''
  end
  return tostring(item.id)
end

local function kidsOf(item)
  local kids = item:children()
  if kids == nil then
    return {}
  end
  return kids
end

local function endsWith(text, suffix)
  if #suffix > #text then
    return false
  end
  return text:sub(-#suffix) == suffix
end

-- The text of every item with no children, in reading order.
local function leafTexts(item, out)
  local parts = out or {}
  if item == nil then
    return parts
  end
  local kids = kidsOf(item)
  if #kids == 0 then
    local text = clean(item.text)
    if text ~= '' then
      parts[#parts + 1] = text
    end
    return parts
  end
  for _, kid in ipairs(kids) do
    leafTexts(kid, parts)
  end
  return parts
end

-- The same node, reached twice in one walk, is the same text in the same
-- place. Two different nodes can share text, such as two closing `end` lines
-- in one code block, so identity has to include the bounds.
local function nodeKey(item)
  local b = item ~= nil and item.bounds or nil
  if b == nil then
    return nil
  end
  return tostring(b.left) .. ',' .. tostring(b.top) .. ',' ..
    tostring(b.right) .. ',' .. tostring(b.bottom) .. '|' .. clean(item.text)
end

-- The items with no children and some text, in reading order.
local function leafItems(item, out)
  local parts = out or {}
  if item == nil then
    return parts
  end
  local kids = kidsOf(item)
  if #kids == 0 then
    if clean(item.text) ~= '' then
      parts[#parts + 1] = item
    end
    return parts
  end
  for _, kid in ipairs(kids) do
    leafItems(kid, parts)
  end
  return parts
end

-- Whether this item or anything inside it is described as `wanted`.
local function hasDesc(item, wanted)
  if item == nil then
    return false
  end
  if descOf(item) == wanted then
    return true
  end
  for _, kid in ipairs(kidsOf(item)) do
    if hasDesc(kid, wanted) then
      return true
    end
  end
  return false
end

local function noteError(error)
  if errorsLogged < MAX_ERRORS_LOGGED then
    print('Could not read the screen: ' .. tostring(error))
  end
  errorsLogged = errorsLogged + 1
end

local function find(query, limit)
  local ok, items = pcall(function()
    return sf.screen.findAll(query, limit)
  end)
  if not ok then
    noteError(items)
    return {}
  end
  return items or {}
end

-- Whether a search finds anything on the screen right now. The search runs
-- inside SandFly and stops at the first match.
local function found(query)
  local ok, item = pcall(function()
    return sf.screen.find(query)
  end)
  if not ok then
    noteError(item)
    return false
  end
  return item ~= nil
end

local function newest(items)
  if #items == 0 then
    return nil
  end
  return items[#items]
end

local function currentPackage()
  local ok, app = pcall(function()
    return sf.app()
  end)
  if not ok or app == nil then
    return nil
  end
  return app.package
end

-- ---------------------------------------------------------------------------
-- Is a reply being written right now? These are Waypoint's signals, looked
-- for with SandFly's own search rather than a walk of the whole screen in
-- Lua: a walk costs a call into the app for every item against the script's
-- time budget, and on a screen with more items than a script may hold at
-- once, the root the walk starts from is the first handle dropped.
-- ---------------------------------------------------------------------------

local function isGenerating(kind)
  if kind == CLAUDE then
    return found({ contentDescription = 'Stop responding' })
      or found({ contentDescription = 'Claude is thinking' })
      or found({ text = 'Sending…' })
  end
  return found({ id = 'assistant_robin_stop_icon_button_compose' })
    or found({ contentDescription = 'Stop generating response' })
end

-- ---------------------------------------------------------------------------
-- The newest reply, per app.
-- ---------------------------------------------------------------------------

-- Defined below, after the per-app readers.

-- Gemini ---------------------------------------------------------------------

local function appendGemini(item, parts)
  local id = idOf(item)
  if endsWith(id, 'assistant_robin_code_block') then
    local impl = item:find({ id = 'assistant_robin_code_impl' })
    local code = impl and clean(impl.text) or ''
    if code ~= '' then
      parts[#parts + 1] = codeBlock(code)
    end
    return
  end
  if endsWith(id, 'assistant_robin_text') then
    local prose = clean(item.text)
    if prose ~= '' then
      parts[#parts + 1] = prose
    end
    return
  end
  for _, kid in ipairs(kidsOf(item)) do
    appendGemini(kid, parts)
  end
end

local function geminiResponse()
  local message = newest(find({ id = 'assistant_robin_message_content' }, 200))
  if message == nil then
    return ''
  end
  local parts = {}
  appendGemini(message, parts)
  return clean(table.concat(parts, string.char(10)))
end

-- Claude ---------------------------------------------------------------------

local function isClaudeCode(item)
  local header = false
  local code = false
  for _, kid in ipairs(kidsOf(item)) do
    if hasDesc(kid, 'Copy code') and hasDesc(kid, 'Expand code') then
      header = true
    elseif #leafTexts(kid, {}) > 0 then
      code = true
    end
  end
  if not (header and code) then
    return false
  end
  for _, kid in ipairs(kidsOf(item)) do
    if isClaudeCode(kid) then
      return false
    end
  end
  return true
end

local function appendClaude(item, parts, seen)
  seen = seen or {}
  if isClaudeCode(item) then
    local code = {}
    local codeSeen = {}
    for _, kid in ipairs(kidsOf(item)) do
      if not hasDesc(kid, 'Copy code') then
        for _, leaf in ipairs(leafItems(kid, {})) do
          local text = clean(leaf.text)
          local key = nodeKey(leaf)
          if text ~= '' and (key == nil or not codeSeen[key]) then
            if key then
              codeSeen[key] = true
            end
            code[#code + 1] = text
          end
        end
      end
    end
    if #code > 0 then
      parts[#parts + 1] = codeBlock(table.concat(code, '\n'))
    end
    return
  end
  local kids = kidsOf(item)
  if #kids == 0 then
    local text = clean(item.text)
    local key = nodeKey(item)
    if text ~= '' and (key == nil or not seen[key]) then
      if key then
        seen[key] = true
      end
      parts[#parts + 1] = text
    end
    return
  end
  for _, kid in ipairs(kids) do
    appendClaude(kid, parts, seen)
  end
end

local function claudeResponse()
  local message = newest(find({ contentDescription = 'Copy message' }, 200))
  if message == nil then
    return ''
  end

  while message do
    local kids = kidsOf(message)
    for index = #kids, 2, -1 do
      local actions = kids[index]
      if actions and hasDesc(actions, 'Copy message') then
        -- Claude puts the prompt and the answer in the same item, ahead of the
        -- actions. The prompt is long-clickable and holds text, so the answer
        -- starts after the last of those.
        local start = 1
        for i = 1, index - 1 do
          local kid = kids[i]
          if kid and kid.longClickable and #leafTexts(kid, {}) > 0 then
            start = i + 1
          end
        end

        local parts = {}
        for i = start, index - 1 do
          local kid = kids[i]
          if kid then
            appendClaude(kid, parts)
          end
        end
        if #parts > 0 then
          return clean(table.concat(parts, string.char(10)))
        end
      end
    end
    message = message:parent()
  end
  return ''
end

-- ---------------------------------------------------------------------------
-- Reading a reply out.
-- ---------------------------------------------------------------------------

local function latestResponse(kind)
  if kind == CLAUDE then
    return claudeResponse()
  end
  return geminiResponse()
end

local function setting(key, fallback)
  local value = sf.settings.get(key)
  if value == nil then
    return fallback
  end
  return value
end

codeBlock = function(code)
  if setting('code', true) == false then
    return code
  end
  return tr(CODE_START) .. '\n' .. code .. '\n' .. tr(CODE_END)
end

local function quietSeconds()
  local value = tonumber(setting('quiet', 3))
  if value == nil or value < 1 then
    return 3
  end
  value = math.floor(value + 0.5)
  if value > 10 then
    value = 10
  end
  return value
end

local function say(text, interrupt)
  sf.speak(text, { interrupt = interrupt and true or false })
end

local function speakGenerating()
  if setting('starting', true) == false then
    return
  end
  local packageName = currentPackage()
  print('Generating in ' .. (NAMES[packageName] or tostring(packageName)))
  say(tr('Generating'), false)
end

-- Read the newest reply, if it is new and the app has stopped writing.
finish = function()
  quiet = nil
  local packageName = currentPackage()
  if not APPS[packageName] then
    return
  end
  if isGenerating(packageName) then
    if retries < MAX_RETRIES then
      retries = retries + 1
      quiet = sf.setTimeout(finish, RETRY_MS)
    else
      print('Gave up waiting for the app to stop writing')
    end
    return
  end
  -- Take the reply as it is now. The text cached by the poll that scheduled
  -- this may be a fragment from before the app finished writing.
  local text = latestResponse(packageName)
  if text == '' then
    pendingText = ''
    print('The reply disappeared before it could be read')
    return
  end
  if text ~= pendingText then
    pendingText = text
    pendingGeneration = generation
    quiet = sf.setTimeout(finish, quietSeconds() * 1000)
    print('The reply changed while waiting; waiting for quiet again')
    return
  end
  retries = 0
  if pendingText == '' then
    print('Nothing to read')
    return
  end
  -- Identical answers to two different questions are two replies. Compare the
  -- generation as well as the text, so the second one is still read.
  if pendingText == spokenText and pendingGeneration <= spokenGeneration then
    print('That reply was already read')
    return
  end
  print('Reading a reply of ' .. #pendingText .. ' characters')
  spokenText = pendingText
  spokenGeneration = pendingGeneration
  say(pendingText, setting('interrupt', false) == true)
end

check = function()
  scheduled = nil
  polls = polls + 1
  if polls > MAX_POLLS and poll then
    sf.clearTimer(poll)
    poll = nil
    print('Stopped polling; waiting for the screen to change')
  end
  local packageName = currentPackage()
  if not APPS[packageName] then
    return
  end

  local writing = isGenerating(packageName)
  if writing and not generating then
    generation = generation + 1
    if pendingText == spokenText then
      -- An answer that comes out identical to the last one is still a new
      -- reply, so mark the text as owing a reading for this generation.
      pendingGeneration = generation
    end
    speakGenerating()
  end
  if writing then
    -- Keep watching while the app writes, however long it takes.
    polls = 0
  end
  generating = writing

  local text = latestResponse(packageName)

  if not baselined then
    -- Whatever reply is already on screen was read last session, or was never
    -- asked for. Only a change from here on is news. An app can still be
    -- drawing when the script loads, so this takes the reply as it settles,
    -- then stops: a reply that arrives after this point is news.
    if text ~= '' then
      pendingText = text
      spokenText = text
      pendingGeneration = generation
      spokenGeneration = generation
    end
    if not baselineDue then
      return -- The screen is still settling.
    end
    baselined = true
    print('Starting from a reply of ' .. #text .. ' characters in ' .. (NAMES[packageName] or packageName))
    return
  end

  if text == '' then
    return
  end

  if text == pendingText then
    -- The text has stopped changing. finish() can have run out of retries
    -- while the app was still writing and left no timer behind, and no
    -- further text change will come to arm one, so arm it here.
    local owed = pendingText ~= spokenText or pendingGeneration > spokenGeneration
    if owed and not writing and quiet == nil then
      polls = 0
      quiet = sf.setTimeout(finish, quietSeconds() * 1000)
      print('A reply is waiting to be read and had no timer')
    end
    return
  end
  pendingText = text
  pendingGeneration = generation
  polls = 0
  if quiet then
    sf.clearTimer(quiet)
  end
  quiet = sf.setTimeout(finish, quietSeconds() * 1000)
  print('A reply of ' .. #text .. ' characters is waiting for quiet in ' .. (NAMES[packageName] or packageName))
end

schedule = function()
  if scheduled then
    return
  end
  scheduled = sf.setTimeout(check, CHECK_DELAY_MS)
end

reset = function()
  pendingText = ''
  spokenText = ''
  pendingGeneration = generation
  spokenGeneration = generation
  generating = false
  baselined = false
  baselineDue = false
  retries = 0
  changes = 0
  if scheduled then
    sf.clearTimer(scheduled)
  end
  if quiet then
    sf.clearTimer(quiet)
  end
  if baselineTimer then
    sf.clearTimer(baselineTimer)
  end
  scheduled = nil
  quiet = nil
  baselineTimer = sf.setTimeout(function()
    baselineDue = true
    check()
  end, BASELINE_MS + 100)
end

local function stopAll()
  if poll then
    sf.clearTimer(poll)
    poll = nil
  end
  if scheduled then
    sf.clearTimer(scheduled)
    scheduled = nil
  end
  if quiet then
    sf.clearTimer(quiet)
    quiet = nil
  end
  if baselineTimer then
    sf.clearTimer(baselineTimer)
    baselineTimer = nil
  end
  pendingText = ''
  spokenText = ''
  generating = false
  baselined = false
  baselineDue = false
  retries = 0
  changes = 0
end

sf.onContentChange(function(event)
  -- Another app's window can change while this one is in front, such as a
  -- keyboard. Only a change in an app this script reads is worth a look.
  if event == nil or not APPS[event.package] then
    return
  end
  changes = changes + 1
  if changes == 1 or changes % 100 == 0 then
    print('Screen changed in ' .. event.package .. ' (' .. changes .. ')')
  end
  -- A change means something happened, so poll again for a while.
  polls = 0
  if poll == nil then
    poll = sf.setInterval(check, POLL_MS)
  end
  schedule()
end)

sf.onAppEnter(function(app)
  -- A script with apps loads when one of them comes to the front.
  reset()
  print('Looking at ' .. tostring(app.package))
  -- Some apps send one content change and then nothing while a reply
  -- streams, so a poll is the only way to see it finish.
  poll = sf.setInterval(check, POLL_MS)
  schedule()
end)

sf.onAppLeave(function()
  stopAll()
end)

print('AI reader loaded')
