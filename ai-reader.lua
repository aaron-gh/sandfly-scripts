-- AI reader: says an AI app's reply once the app has finished writing it.
--
-- This is the Backtalk script of the same name (JavaScript) ported to SandFly's
-- Lua scripting API. It is a port of Waypoint, an accessibility service.
--
-- The per-app rules below are Waypoint's measured rules, kept as they were:
-- Gemini's view ids, ChatGPT's "Read aloud" row, and Claude's "Copy message"
-- row. Each is an implementation detail of that app and may break in a future
-- release. The Log on this script's page says what it pulled out of the
-- screen, so a break can be told apart from a quiet conversation.

local manifest = {
  id = 'ai-reader',
  name = 'AI reader',
  version = '1.11',
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
local CHATGPT = 'com.openai.chatgpt'
local CLAUDE = 'com.anthropic.claude'
local APPS = { [GEMINI] = true, [CHATGPT] = true, [CLAUDE] = true }
local NAMES = { [GEMINI] = 'Gemini', [CHATGPT] = 'ChatGPT', [CLAUDE] = 'Claude' }

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

-- Whether two snapshots are the same item, by identity or by id and bounds.
local function sameItem(a, b)
  if a == b then
    return true
  end
  if a == nil or b == nil then
    return false
  end
  if idOf(a) ~= idOf(b) or idOf(a) == '' then
    return false
  end
  local ba, bb = a.bounds, b.bounds
  if ba == nil or bb == nil then
    return false
  end
  return ba.left == bb.left and ba.top == bb.top and ba.right == bb.right and ba.bottom == bb.bottom
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

local function contains(list, wanted)
  for _, value in ipairs(list) do
    if value == wanted then
      return true
    end
  end
  return false
end

-- Whether any item at or inside this one has exactly this text.
local function hasText(item, wanted)
  return contains(leafTexts(item, {}), wanted)
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
-- Is a reply being written right now? These are Waypoint's signals.
-- ---------------------------------------------------------------------------

local function isGenerating(root, kind)
  if kind == CHATGPT then
    return hasDesc(root, 'Stop') or hasText(root, 'Thinking')
  end
  if kind == CLAUDE then
    return hasDesc(root, 'Stop responding')
      or hasDesc(root, 'Claude is thinking')
      or hasText(root, 'Sending…')
  end
  return #find({ id = 'assistant_robin_stop_icon_button_compose' }, 1) > 0
    or hasDesc(root, 'Stop generating response')
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

-- ChatGPT --------------------------------------------------------------------

local function chatGptCode(item)
  local control = item:find({ contentDescription = 'Copy code' })
  if control == nil then
    return nil
  end
  local header = control
  while header and #leafTexts(header, {}) == 0 do
    header = header:parent()
  end
  if header == nil then
    return nil
  end
  local container = header:parent()
  if container == nil or not sameItem(container, item) then
    return nil
  end
  local code = {}
  for _, kid in ipairs(kidsOf(container)) do
    if kid and not sameItem(kid, header) then
      for _, text in ipairs(leafTexts(kid, {})) do
        if not contains(code, text) then
          code[#code + 1] = text
        end
      end
    end
  end
  if #code == 0 then
    return nil
  end
  return table.concat(code, '\n')
end

local function isSuggestion(textItem, boundary)
  local item = textItem:parent()
  while item and not sameItem(item, boundary) do
    if item.clickable then
      local parent = item:parent()
      return parent ~= nil and #leafTexts(parent, {}) > 1
    end
    item = item:parent()
  end
  return false
end

local function appendChatGpt(item, boundary, parts)
  local code = chatGptCode(item)
  if code ~= nil then
    parts[#parts + 1] = codeBlock(code)
    return
  end
  local kids = kidsOf(item)
  if #kids == 0 then
    if isSuggestion(item, boundary) then
      return
    end
    local text = clean(item.text)
    if text ~= '' and not contains(parts, text) then
      parts[#parts + 1] = text
    end
    return
  end
  for _, kid in ipairs(kids) do
    appendChatGpt(kid, boundary, parts)
  end
end

-- The row of one reply: the nearest ancestor that holds just this reply's
-- Read aloud control and some text of its own. Without this, opening the
-- keyboard can make every reply share one container, and the whole
-- conversation gets read as one answer.
local function textOutsideAnchor(item)
  local parts = {}
  for _, kid in ipairs(kidsOf(item)) do
    if not hasDesc(kid, 'Read aloud') then
      for _, text in ipairs(leafTexts(kid, {})) do
        parts[#parts + 1] = text
      end
    end
  end
  return parts
end

local function anchorCount(item)
  local count = 0
  if descOf(item) == 'Read aloud' then
    count = count + 1
  end
  for _, kid in ipairs(kidsOf(item)) do
    count = count + anchorCount(kid)
  end
  return count
end

-- The reply lowest on the screen, which is the newest one, whatever order the
-- app lists its items in.
local function newestAnchor(anchors)
  local best = anchors[1]
  for _, anchor in ipairs(anchors) do
    local a, b = anchor.bounds, best.bounds
    if a and b and a.top > b.top then
      best = anchor
    end
  end
  return best
end

-- Some ChatGPT conversations expose no Read aloud controls at all, only plain
-- text. Then the reply is what sits below the last message the user sent, which
-- is the bubble whose row is clickable and indented from the left.
local function collectFlat(node, width, container, out)
  local current = container
  local b = node.bounds
  if node.clickable and node.longClickable and b and b.left > width * 0.3 then
    current = b
  end
  local kids = kidsOf(node)
  if #kids == 0 then
    local text = clean(node.text)
    if text ~= '' and b then
      out[#out + 1] = { text = text, top = b.top, container = current, editable = node.editable }
    end
    return
  end
  for _, kid in ipairs(kids) do
    collectFlat(kid, width, current, out)
  end
end

local function flatChatGptResponse(root)
  if root == nil then
    return nil
  end
  local rb = root.bounds
  local width = rb and (rb.right - rb.left) or 1080
  local nodes = {}
  collectFlat(root, width, nil, nodes)
  local lastUser, lastTop = nil, -1
  for _, node in ipairs(nodes) do
    if node.container and node.container.top > lastTop then
      lastTop = node.container.top
      lastUser = node.container
    end
  end
  if lastUser == nil then
    return nil
  end
  local parts = {}
  for _, node in ipairs(nodes) do
    local text = node.text
    if node.top > lastUser.bottom
      and not node.editable
      and text ~= 'Ask ChatGPT'
      and text ~= 'Reply to ChatGPT'
      and text ~= 'Message ChatGPT'
      and not contains(parts, text) then
      parts[#parts + 1] = text
    end
  end
  if #parts == 0 then
    return nil
  end
  return clean(table.concat(parts, string.char(10)))
end

local function chatGptResponse(root)
  local anchors = find({ contentDescription = 'Read aloud' }, 200)
  if #anchors == 0 then
    return flatChatGptResponse(root) or ''
  end
  local anchor = newestAnchor(anchors)
  local row = anchor:parent()
  while row do
    if anchorCount(row) == 1 and #textOutsideAnchor(row) > 0 then
      break
    end
    row = row:parent()
  end
  if row == nil then
    return ''
  end

  local parts = {}
  for _, kid in ipairs(kidsOf(row)) do
    if not hasDesc(kid, 'Read aloud') then
      appendChatGpt(kid, row, parts)
    end
  end

  -- A writing card puts a short card title before the answer. It is the topic,
  -- not the answer. Waypoint dropped any short first part; a line that leads
  -- into a code block, such as "Run this:", reads the same way, so it is kept.
  if #parts >= 2
    and parts[1] ~= CODE_START
    and parts[2] ~= CODE_START
    and not endsWith(parts[1], ':')
    and #parts[1] <= 80
    and #parts[2] > #parts[1] * 2 then
    table.remove(parts, 1)
  end
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

local function appendClaude(item, parts)
  if isClaudeCode(item) then
    local code = {}
    for _, kid in ipairs(kidsOf(item)) do
      if not hasDesc(kid, 'Copy code') then
        for _, text in ipairs(leafTexts(kid, {})) do
          if not contains(code, text) then
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
    if text ~= '' and not contains(parts, text) then
      parts[#parts + 1] = text
    end
    return
  end
  for _, kid in ipairs(kids) do
    appendClaude(kid, parts)
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

local function latestResponse(root, kind)
  if kind == CHATGPT then
    return chatGptResponse(root)
  end
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
  return CODE_START .. '\n' .. code .. '\n' .. CODE_END
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
  say('Generating', false)
end

-- Read the newest reply, if it is new and the app has stopped writing.
finish = function()
  quiet = nil
  local packageName = currentPackage()
  if not APPS[packageName] then
    return
  end
  local ok, root = pcall(function()
    return sf.screen.root()
  end)
  if not ok then
    noteError(root)
    return
  end
  if root == nil then
    return
  end
  if isGenerating(root, packageName) then
    if retries < MAX_RETRIES then
      retries = retries + 1
      quiet = sf.setTimeout(finish, RETRY_MS)
    else
      print('Gave up waiting for the app to stop writing')
    end
    return
  end
  retries = 0
  if pendingText == '' then
    print('Nothing to read')
    return
  end
  if pendingText == spokenText then
    print('That reply was already read')
    return
  end
  print('Reading a reply of ' .. #pendingText .. ' characters:\n' .. pendingText)
  spokenText = pendingText
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
  local ok, root = pcall(function()
    return sf.screen.root()
  end)
  if not ok then
    noteError(root)
    return
  end
  if root == nil then
    return
  end

  local writing = isGenerating(root, packageName)
  if writing and not generating then
    speakGenerating()
  end
  if writing then
    -- Keep watching while the app writes, however long it takes.
    polls = 0
  end
  generating = writing

  local text = latestResponse(root, packageName)

  if not baselined then
    -- Whatever reply is already on screen was read last session, or was never
    -- asked for. Only a change from here on is news. An app can still be
    -- drawing when the script loads, so this takes the reply as it settles,
    -- then stops: a reply that arrives after this point is news.
    if text ~= '' then
      pendingText = text
      spokenText = text
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
    return
  end
  pendingText = text
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
  -- Some apps, ChatGPT among them, send one content change and then nothing
  -- while a reply streams, so a poll is the only way to see it finish.
  poll = sf.setInterval(check, POLL_MS)
  schedule()
end)

sf.onAppLeave(function()
  stopAll()
end)

print('AI reader loaded')
