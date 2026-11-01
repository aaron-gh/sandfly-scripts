local manifest = {
  id = 'openbubbles-messages',
  name = 'OpenBubbles messages',
  version = '1.0',
  author = 'Aaron Hewitt',
  minApiVersion = 2,
  testedApiVersion = 2,
  description = 'Reads each message in an OpenBubbles chat as one item: sender, content, link preview, the message it replies to and its reply count. Dates are separate items, and contact initials are left out. In the list of conversations, each conversation is read without its initials, and Mark Unread, Pin, Mute and Delete are in its Actions menu.',
  apps = { 'com.openbubbles.messaging' },
  permissions = { 'screen', 'actions', 'speech', 'input', 'system' },
  rules = {
    -- A message row, and the views between the row and its bubble. With these hidden, the row's
    -- date and the bubble are separate items. The sender's name and initials are hidden by rules
    -- the script adds while a chat is open.
    {
      match = { className = '.View', clickable = false, inside = { scrollable = true }, has = { longClickable = true } },
      hide = true,
    },
    -- The view around a message in a reply thread. Clicking it opens the thread, which is in the
    -- message's Actions menu.
    {
      match = { clickable = true, longClickable = false, inside = { scrollable = true }, has = { longClickable = true } },
      hide = true,
    },
    -- The quote above a reply, read with the reply.
    {
      match = { clickable = true, longClickable = false, inside = { scrollable = true }, has = { textContains = ' repl' } },
      hide = 'all',
    },
    -- The reply thread, shown over the chat. Clicking it closes it.
    {
      match = { clickable = true, longClickable = false, has = { longClickable = true } },
      label = 'Close reply thread',
    },
    -- A message's reply count, read with the message.
    {
      match = {
        className = 'TextView',
        textContains = ' repl',
        inside = { { clickable = true, longClickable = false }, { scrollable = true } },
      },
      hide = true,
    },
  },
}

local tr = sf._

-- OpenBubbles is built with Jetpack Compose and gives its views no ids, so items are found by
-- their kind, their state and where they are.
local MAX_ROW_ITEMS = 120
local MAX_OLDER_ROWS = 4
local MAX_LISTS = 4
local MAX_TITLE_ITEMS = 20
local MAX_INITIALS = 3
-- How many views up from a bubble its list can be.
local MAX_DEPTH = 7
-- How far a sender's name can be above its bubble, and from the bubble's left edge, in pixels.
local NAME_GAP = 60
local NAME_INDENT = 40
local MENU_TRIES = 8
local MENU_DELAY = 150

local CONVERSATION_ACTIONS = {
  { title = 'Mark Unread or Read', labels = { 'Mark Unread', 'Mark Read' } },
  { title = 'Pin or Unpin', labels = { 'Pin', 'Unpin' } },
  { title = 'Mute or Unmute', labels = { 'Mute', 'Unmute' } },
  { title = 'Delete', labels = { 'Delete' } },
}

local function present(text)
  if text ~= nil and text ~= '' then
    return text
  end
end

-- Joins the parts that aren't nil, false or empty.
local function join(parts, separator)
  local kept = {}
  for i = 1, parts.n or #parts do
    local part = parts[i]
    if part and part ~= '' then
      kept[#kept + 1] = part
    end
  end
  return table.concat(kept, separator)
end

-- Removes the direction marks U+200B to U+200F, U+202A to U+202E and U+2066 to U+2069, and makes
-- the narrow no-break space U+202F a space.
local function clean(text)
  text = (text or ''):gsub('\226\128[\139-\143\170-\174]', '')
  text = text:gsub('\226\129[\166-\169]', '')
  text = text:gsub('\226\128\175', ' ')
  return (text:match('^%s*(.-)%s*$'))
end

local function own_text(item)
  return clean(present(item.text) or item.contentDescription)
end

local function ends_with(text, suffix)
  return (text or ''):sub(-#suffix) == suffix
end

local function is_text(item)
  return ends_with(item.className, 'TextView')
end

-- A message bubble, or a row in the list of conversations.
local function is_bubble(item)
  return item.clickable and item.longClickable and ends_with(item.className, '.View')
end

local function is_reply_count(text)
  return text:match('^%d+ [Rr]epl') ~= nil
end

local function within(inner, outer)
  local a, b = inner.bounds, outer.bounds
  return a.left >= b.left and a.right <= b.right and a.top >= b.top and a.bottom <= b.bottom
end

local function same_bounds(a, b)
  local x, y = a.bounds, b.bounds
  return x.left == y.left and x.right == y.right and x.top == y.top and x.bottom == y.bottom
end

-- The row a bubble is in, and the list of rows it is in: the chat's scrolling list, or the view of
-- a reply thread, which is shown over the chat and closes when clicked. In the list of
-- conversations, the row is the bubble itself.
local function context_of(bubble)
  local chain = { bubble }
  for i = 2, MAX_DEPTH do
    local current = chain[i - 1]:parent()
    if not current then
      break
    end
    if current.scrollable then
      return chain[i - 1], current
    end
    chain[i] = current
  end
  -- The reply thread's view is the highest one that is inside a clickable view of the same bounds.
  -- Lower ones are the views around messages in a reply thread.
  for i = #chain - 1, 2, -1 do
    local above = chain[i + 1]
    if above.clickable and not above.longClickable and same_bounds(above, chain[i]) then
      return chain[i - 1], chain[i]
    end
  end
end

-- Reads a message row: its bubble, and the texts around the bubble by where they are. Gives nil
-- for a row without a bubble, such as a date on its own.
local function read_message(row, bubble)
  local items = row:findAll({}, MAX_ROW_ITEMS)
  if not bubble then
    for _, item in ipairs(items) do
      if item ~= row and is_bubble(item) then
        bubble = item
        break
      end
    end
    if not bubble then
      return nil
    end
  end
  local b, w = bubble.bounds, row.bounds
  local r = {
    row = row,
    bubble = bubble,
    -- Sent messages sit against the right edge.
    outgoing = w.right - b.right < b.left - w.left,
    content = {},
    quoted = {},
    extra = {},
  }
  for _, item in ipairs(items) do
    if item ~= row and item ~= bubble then
      if item.clickable and not item.longClickable then
        if within(bubble, item) then
          r.thread = item
        else
          r.quote = item
        end
      elseif not is_text(item) and own_text(item) == '' and within(item, bubble)
          and (item.bounds.right - item.bounds.left) * 2 >= b.right - b.left then
        r.image = true
      end
    end
  end
  local seen = {}
  for _, item in ipairs(items) do
    local text = item ~= row and item ~= bubble and own_text(item) or ''
    if text ~= '' then
      local a = item.bounds
      if within(item, bubble) then
        if not seen[text] then
          seen[text] = true
          r.content[#r.content + 1] = text
        end
      elseif r.quote and within(item, r.quote) then
        if not is_reply_count(text) then
          r.quoted[#r.quoted + 1] = text
        end
      elseif is_reply_count(text) then
        r.count = text
      elseif is_text(item) and a.left <= w.left + 2 and a.right >= w.right - 2 then
        -- The date, which spans the row. It is an item of its own.
      elseif is_text(item) and a.bottom <= b.top + 4 and b.top - a.bottom <= NAME_GAP
          and math.abs(a.left - b.left) <= NAME_INDENT then
        r.name = text
      elseif is_text(item) and a.left < b.left and a.right <= b.left + 8
          and utf8.len(text) and utf8.len(text) <= MAX_INITIALS then
        r.initials = text
      else
        r.extra[#r.extra + 1] = text
      end
    end
  end
  -- A link preview: a picture, a title, sometimes a description, and the address's domain last.
  local last = r.content[#r.content]
  r.link = #r.content >= 1 and r.image or #r.content >= 2 and last:match('^[%w%-]+%.[%w%-%.]*%a$') ~= nil
  return r
end

-- The chat's title, and whether it is a group, kept until the window changes.
local chat = nil
local function chat_info()
  if chat then
    return chat
  end
  chat = { title = nil, group = false }
  local back = sf.screen.find({ contentDescription = 'Back' })
  local bar = back and back:parent()
  bar = bar and bar:parent()
  if bar then
    -- The title is the widest text; a group's picture shows the initials of several people.
    local widest, initials = nil, 0
    for _, item in ipairs(bar:findAll({ className = 'TextView' }, MAX_TITLE_ITEMS)) do
      local text = clean(item.text)
      if text ~= '' then
        local width = item.bounds.right - item.bounds.left
        if not widest or width > widest.width then
          widest = { text = text, width = width }
        end
        if (utf8.len(text) or MAX_INITIALS + 1) <= MAX_INITIALS then
          initials = initials + 1
        end
      end
    end
    chat.title = widest and widest.text
    chat.group = initials >= 2
  end
  return chat
end

-- A message without a name of its own is from the sender of the messages above it, up to a sent
-- message. In a chat with one person, messages have no names.
local function sender_of(r, rows)
  if r.name then
    return r.name
  end
  if r.outgoing then
    return tr('You')
  end
  local older = {}
  for _, row in ipairs(rows) do
    if row ~= r.row and row.bounds.bottom <= r.row.bounds.top + 2 then
      older[#older + 1] = row
    end
  end
  table.sort(older, function(a, b) return a.bounds.top > b.bounds.top end)
  for i = 1, math.min(#older, MAX_OLDER_ROWS) do
    local o = read_message(older[i])
    if o then
      if o.outgoing then
        break
      end
      if o.name then
        return o.name
      end
    end
  end
  local info = chat_info()
  if not info.group then
    return info.title
  end
end

local function describe_message(r, sender)
  local body = table.concat(r.content, ', ')
  if r.link then
    body = tr('link') .. ': ' .. body
  end
  local quote = #r.quoted > 0 and (tr('in reply to') .. ': ' .. table.concat(r.quoted, ', ')) or nil
  return join(table.pack(sender, body, quote, r.count, table.concat(r.extra, ', ')), ', ')
end

-- A row in the list of conversations: the name, the last message and the time. The picture, with
-- the contact's initials, is left out.
local function describe_conversation(row)
  local parts = {}
  for _, child in ipairs(row:children()) do
    local text = is_text(child) and clean(child.text) or clean(child.contentDescription)
    if text ~= '' then
      parts[#parts + 1] = text
    end
  end
  return table.concat(parts, ', ')
end

-- Names and initials are hidden by their text while a chat is open, since nothing else tells them
-- from the dates around them.
local hidden = {}
local function hide_texts(texts)
  for text in pairs(texts) do
    if not hidden[text] then
      hidden[text] = sf.rules.add({ match = { className = 'TextView', text = text, clickable = false }, hide = true })
    end
  end
end

local function show_all()
  if next(hidden) then
    sf.rules.clear()
    hidden = {}
  end
end

-- The lists of messages on screen. Rows in the list of conversations can be long-clicked; message
-- rows can't.
local function message_lists()
  local lists = {}
  if not sf.screen.find({ contentDescription = 'FaceTime' }) then
    return lists
  end
  for _, list in ipairs(sf.screen.findAll({ scrollable = true }, MAX_LISTS)) do
    local first = list:child(1)
    if first and not (first.clickable and first.longClickable) then
      lists[#lists + 1] = list
    end
  end
  return lists
end

-- The rows looked at last, so that a scan of the same rows reads nothing more.
local last_rows = ''
local function scan()
  local lists = message_lists()
  if #lists == 0 then
    last_rows = ''
    show_all()
    return
  end
  local rows, keys = {}, {}
  for _, list in ipairs(lists) do
    for _, row in ipairs(list:children()) do
      local box = row.bounds
      rows[#rows + 1] = row
      keys[#keys + 1] = table.concat({ box.left, box.top, box.right, box.bottom, row.childCount }, ' ')
    end
  end
  local key = table.concat(keys, ',')
  if key == last_rows then
    return
  end
  last_rows = key
  local texts = {}
  for _, row in ipairs(rows) do
    local r = read_message(row)
    if r and r.name then
      texts[r.name] = true
      chat_info().group = true
    end
    if r and r.initials then
      texts[r.initials] = true
    end
  end
  hide_texts(texts)
end

local scan_timer = nil
local function schedule_scan(delay)
  if scan_timer then
    return
  end
  scan_timer = sf.setTimeout(function()
    scan_timer = nil
    local ok, problem = pcall(scan)
    if not ok then
      sf.log.warn(problem)
    end
  end, delay or 300)
end

sf.onWindowChange(function()
  chat = nil
  last_rows = ''
  schedule_scan()
end)
sf.onScroll(function()
  schedule_scan()
end)
sf.onContentChange(function()
  schedule_scan(1000)
end)

-- Each focus is counted, so that an item read after focus moved on isn't said.
local focus_count = 0

-- Reads the focused item and says it, or what SandFly would have said, [fallback], if it isn't a
-- message or a conversation.
local function say_item(item, fallback, count)
  local ok, text = pcall(function()
    local row, list = context_of(item)
    if not row then
      return nil
    end
    if row == item then
      return describe_conversation(item)
    end
    local r = read_message(row, item)
    return r and describe_message(r, sender_of(r, list:children()))
  end)
  if not ok then
    sf.log.warn(text)
    text = nil
  end
  text = present(text) or fallback
  if count == focus_count and present(text) then
    sf.speak(text, { interrupt = true })
  end
end

sf.onFocus(function(item, text)
  focus_count = focus_count + 1
  -- Only the item's own fields are looked at here, which needs no call to OpenBubbles. Reading
  -- the row takes longer than the 30 milliseconds SandFly waits for onFocus, so a timer reads it
  -- once onFocus has returned.
  if not is_bubble(item) then
    return
  end
  sf.setTimeout(say_item, 0, item, text, focus_count)
  return false
end)

-- The entry of the conversation menu with one of [labels]. The entries can be checked.
local function menu_entry(labels)
  for _, label in ipairs(labels) do
    local entry = sf.screen.find({ checkable = true, has = { text = label } })
    if entry then
      return entry, label
    end
  end
  for _, window in ipairs(sf.screen.windows()) do
    if window.type == 'application' and window.root then
      for _, label in ipairs(labels) do
        local entry = window.root:find({ checkable = true, has = { text = label } })
        if entry then
          return entry, label
        end
      end
    end
  end
end

local function any_menu_entry()
  local labels = {}
  for _, action in ipairs(CONVERSATION_ACTIONS) do
    for _, label in ipairs(action.labels) do
      labels[#labels + 1] = label
    end
  end
  return menu_entry(labels)
end

-- Runs when an Actions menu entry is chosen: opens the conversation's menu and chooses the entry.
local function run_conversation_action(row, action)
  -- SandFly's Actions menu closes first.
  sf.sleep(400)
  if not row:longClick() then
    sf.speak(tr('Could not open the conversation menu'))
    return
  end
  for _ = 1, MENU_TRIES do
    local entry, label = menu_entry(action.labels)
    if entry then
      entry:click()
      sf.speak(tr(label))
      return
    end
    sf.sleep(MENU_DELAY)
  end
  sf.speak(tr(action.title) .. ': ' .. tr('not in the conversation menu'))
  if any_menu_entry() then
    sf.system.back()
  end
end

sf.onActions(function(item)
  if not is_bubble(item) then
    return nil
  end
  local row = context_of(item)
  if not row then
    return nil
  end
  if row == item then
    local actions = {}
    for _, action in ipairs(CONVERSATION_ACTIONS) do
      actions[#actions + 1] = { title = tr(action.title), run = function() run_conversation_action(item, action) end }
    end
    return actions
  end
  local r = read_message(row, item)
  local target = r and (r.thread or r.quote)
  if target then
    return { { title = tr('Open reply thread'), run = function() target:click() end } }
  end
end)
-- SandFly signature: MEQCIGHyXIrC7h/blUMG2rGmX4V4KITC4bIbAcUD+nlPpSRqAiBcHHTe1RSjV9sLhjYb61hJTuWlYis5iaS7IZWGJ1Dzjg==
