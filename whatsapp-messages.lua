local manifest = {
  id = 'whatsapp-messages',
  name = 'WhatsApp messages',
  version = '3.2',
  author = 'Aaron Hewitt',
  minApiVersion = 1,
  testedApiVersion = 1,
  description = 'Reads each message in a WhatsApp chat as one item: sender, content, the message it replies to, and time. Play, playback speed and the other buttons in a message are in its Actions menu.',
  apps = {
    { package = 'com.whatsapp', activity = 'Conversation' },
    { package = 'com.whatsapp.w4b', activity = 'Conversation' },
  },
  permissions = { 'screen', 'actions', 'speech', 'input' },
  settings = { { key = 'expandLong', type = 'switch', title = 'Expand long messages', default = true } },
  rules = {
    { match = { parentId = 'list', className = 'ViewGroup' }, group = true },
    {
      match = { clickable = true, inside = { parentId = 'list', className = 'ViewGroup' } },
      hide = 'all',
    },
    {
      match = { className = 'SeekBar', inside = { parentId = 'list', className = 'ViewGroup' } },
      hide = true,
      silence = true,
    },
    -- A voice message's time, which counts up each second while it plays.
    { match = { id = 'description', inside = { parentId = 'list', className = 'ViewGroup' } }, silence = true },
  },
}

local tr = sf._

-- A message row is read with one search, which gives the row and everything in it, so that the
-- rest of the script looks things up in the script instead of asking WhatsApp again. Every call
-- to the app takes time, more than the 30 milliseconds SandFly waits for onFocus, so the row is
-- read in a task and said when it is ready.
local MAX_ROW_ITEMS = 200
local MAX_BUTTONS = 24
local MAX_OPTIONS = 20
local MAX_REACTIONS = 8
local MAX_NOTICES = 5
local LABEL_DEPTH = 3
local MAX_BUBBLE_ITEMS = 60
local MAX_BUBBLE_TEXTS = 6

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

local function short_id(item)
  return (item.id or ''):match('[^/]*$')
end

-- Removes the direction marks WhatsApp adds, U+200B to U+200F, U+202A to U+202E and U+2066 to
-- U+2069, and the "~" before a name the contact list doesn't have.
local function clean(text)
  text = (text or ''):gsub('\226\128[\139-\143\170-\174]', '')
  text = text:gsub('\226\129[\166-\169]', '')
  -- The narrow no-break space after the "~", U+202F.
  text = text:gsub('\226\128\175', ' ')
  text = text:match('^%s*(.-)%s*$')
  text = text:gsub('^~%s*', '')
  return (text:match('^%s*(.-)%s*$'))
end

-- Gives the list of messages that the row is in, or nil if the item isn't a message row.
local function list_of(item)
  if short_id(item):sub(1, 17) ~= 'conversation_row_' then
    return nil
  end
  local parent = item:parent()
  if parent and (parent.id or ''):sub(-5) == '/list' then
    return parent
  end
end

-- The row and everything in it, by short id.
local function read_row(row, list)
  local items = row:findAll({}, MAX_ROW_ITEMS)
  local by_id = {}
  for _, item in ipairs(items) do
    local id = short_id(item)
    if id ~= '' then
      local found = by_id[id]
      if not found then
        found = {}
        by_id[id] = found
      end
      found[#found + 1] = item
    end
  end
  return { node = row, list = list, items = items, by_id = by_id }
end

local function first(r, id)
  local found = r.by_id[id]
  return found and found[1]
end

local function all_of(r, id, limit)
  local found = r.by_id[id] or {}
  local result = {}
  for i = 1, math.min(#found, limit) do
    result[i] = found[i]
  end
  return result
end

local function text_in(r, id)
  local found = first(r, id)
  return found and clean(found.text) or ''
end

local function main_of(r)
  return first(r, 'main_layout') or first(r, 'polls_main_layout')
end

-- Sent messages have a delivery status and sit against the right edge.
local function is_outgoing(r)
  if first(r, 'status') then
    return true
  end
  local main = main_of(r)
  local row = r.node
  return main ~= nil and row.bounds.right - main.bounds.right < main.bounds.left - row.bounds.left
end

-- Whether the chat is a group, and the contact's name if not, kept for each chat.
local chats = {}

-- In a chat with one person, the messages from them have no name and no picture.
local function contact_name(list)
  if not list then
    return ''
  end
  local chat = chats[list.handle]
  if not chat then
    local is_group = false
    for _, id in ipairs({ 'name_in_group_tv', 'group_profile_pic', 'group_profile_initials' }) do
      if list:find(id) then
        is_group = true
        break
      end
    end
    local title = not is_group and sf.screen.find('conversation_contact_name') or nil
    chat = { name = title and clean(title.text) or '' }
    chats[list.handle] = chat
  end
  return chat.name
end

-- Splits "54 seconds, 09:11, played" into the body, the time and what follows the time.
local function split_time(rest)
  local init = 1
  while true do
    local s, e, time = rest:find(',%s*(%d%d?:%d%d)', init)
    if not s then
      return nil
    end
    local tail = rest:sub(e + 1)
    local ampm = tail:match('^%s?[aApP][mM]')
    if ampm then
      time = time .. ampm
      tail = tail:sub(#ampm + 1)
    end
    if tail == '' then
      return rest:sub(1, s - 1), time, nil
    end
    local state = tail:match('^,%s*(.*)$')
    if state then
      return rest:sub(1, s - 1), time, state
    end
    init = s + 1
  end
end

-- "Alex Smith, voice message, 54 seconds, 09:11" has the sender first, and the time and "played"
-- last. A sound file reads "audio message" instead, and its row also shows the file name.
local function voice_of(r)
  if r.voice == nil then
    r.voice = false
    local main = first(r, 'main_layout')
    local description = main and main.contentDescription or ''
    local voice_at = description:find(', voice message', 1, true)
    local audio_at = description:find(', audio message', 1, true)
    local at = voice_at and audio_at and math.min(voice_at, audio_at) or voice_at or audio_at
    if at then
      local rest = description:sub(at + 2)
      local file = short_id(r.node) == 'conversation_row_audio' and text_in(r, 'description') or ''
      local body, time, state = split_time(rest)
      r.voice = {
        sender = clean(description:sub(1, at - 1)),
        body = join({ body or rest, file }, ', '),
        time = time or '',
        state = state or '',
      }
    end
  end
  return r.voice or nil
end

-- "Poll from Alex Smith, next event.\nSelect one or more\n..."; each option reads "Name, 2 votes".
local function poll_of(r)
  if r.poll == nil then
    r.poll = false
    local main = first(r, 'polls_main_layout')
    if main then
      local name = text_in(r, 'poll_name')
      local description = main.contentDescription or ''
      local end_at = description:find(', ' .. name .. '.', 1, true)
      local parts = { tr('poll') .. ': ' .. name, text_in(r, 'poll_type_text') }
      for _, option in ipairs(all_of(r, 'poll_option_main_layout', MAX_OPTIONS)) do
        local label = clean(option.contentDescription)
        parts[#parts + 1] = option.checked and (tr('selected') .. ' ' .. label) or label
      end
      local prefix = 'Poll from '
      r.poll = {
        sender = description:sub(1, #prefix) == prefix and end_at
            and clean(description:sub(#prefix + 1, end_at - 1)) or '',
        body = join(parts, '. '),
      }
    end
  end
  return r.poll or nil
end

-- A message from the same sender as the one before it has no name of its own.
local function sender_of(r, depth)
  depth = depth or 3
  local named = text_in(r, 'name_in_group_tv')
  if named ~= '' then
    return named
  end
  local known = (voice_of(r) or poll_of(r) or {}).sender
  if present(known) then
    return known
  end
  if is_outgoing(r) then
    return tr('You')
  end
  if depth > 0 and r.list then
    local rows = r.rows or r.list:children()
    for i, sibling in ipairs(rows) do
      if sibling == r.node then
        local previous = i > 1 and rows[i - 1] or nil
        if previous then
          local p = read_row(previous, r.list)
          p.rows = rows
          if not is_outgoing(p) then
            local name = present(sender_of(p, depth - 1))
            if name then
              return name
            end
          end
        end
        break
      end
    end
  end
  return contact_name(r.list)
end

-- "Voice message, 2 minutes, 33 seconds elapsed"; "0 seconds elapsed" before it has played.
local function elapsed_of(r)
  local seek_bar = first(r, 'audio_seekbar')
  local elapsed = seek_bar and (seek_bar.contentDescription or ''):match('^Voice message, (.*) elapsed$')
  if elapsed and elapsed ~= '0 seconds' then
    return elapsed .. ' ' .. tr('elapsed')
  end
  return ''
end

local function label_of(item, depth)
  depth = depth or LABEL_DEPTH
  local own = clean(present(item.contentDescription) or item.text)
  if own ~= '' or depth == 0 then
    return own
  end
  for _, child in ipairs(item:children()) do
    local label = label_of(child, depth - 1)
    if label ~= '' then
      return label
    end
  end
  return ''
end

local function document_of(r)
  if short_id(r.node) ~= 'conversation_row_document' then
    return ''
  end
  local content = first(r, 'content')
  local label = content and label_of(content) or ''
  return label ~= '' and (tr('document') .. ': ' .. label) or tr('document')
end

-- "Enlarge photo", or "Photo 331 kB" before it is downloaded.
local function photo_of(r)
  if short_id(r.node) ~= 'conversation_row_image' then
    return ''
  end
  local image = first(r, 'image')
  local label = clean(image and image.contentDescription)
  if label == '' or label:lower() == 'enlarge photo' then
    return tr('photo')
  end
  if label:sub(1, 5):lower() == 'photo' then
    return tr('photo') .. label:sub(6)
  end
  return label
end

local function reply_of(r)
  if not first(r, 'quoted_message_holder') then
    return ''
  end
  local author = text_in(r, 'quoted_title')
  local quoted = text_in(r, 'quoted_text')
  return join({ (tr('in reply to') .. ' ' .. author):match('^%s*(.-)%s*$'), quoted }, ': ')
end

-- A link's preview repeats the link; only a title that isn't the address is worth saying, unless
-- the message is only the link, which WhatsApp then shows as the preview alone.
local function preview_of(r, alone)
  local title = text_in(r, 'title')
  local is_address = title:find('^https?://') or title:find('^www%.')
  local named
  if title ~= '' and not is_address then
    named = title
  elseif alone then
    named = present(text_in(r, 'url')) or title
  end
  if not present(named) then
    return ''
  end
  return tr(first(r, 'play_button') and 'video link' or 'link') .. ': ' .. named
end

-- The time and status are said on their own, so a message of a kind not handled above is read
-- from the rest of the text in its bubble.
local SKIP_IDS = { date = true, status = true, name_in_group_tv = true, conversation_row_date_divider = true }
local function bubble_text_of(r)
  local main = main_of(r)
  if not main then
    return ''
  end
  local texts, seen = {}, {}
  for _, item in ipairs(main:findAll({}, MAX_BUBBLE_ITEMS)) do
    if #texts >= MAX_BUBBLE_TEXTS then
      break
    end
    if not SKIP_IDS[short_id(item)] then
      local own = clean(present(item.contentDescription) or item.text)
      if own ~= '' and not seen[own] then
        seen[own] = true
        texts[#texts + 1] = own
      end
    end
  end
  return table.concat(texts, ', ')
end

local function reactions_of(r)
  local reactions = {}
  for _, reaction in ipairs(all_of(r, 'reaction_bubble_emoji_text', MAX_REACTIONS)) do
    reactions[#reactions + 1] = clean(reaction.text)
  end
  if #reactions == 0 then
    return ''
  end
  return tr('reactions') .. ' ' .. table.concat(reactions, ' ')
end

local function describe(r)
  local voice = voice_of(r)
  local poll = not voice and poll_of(r) or nil
  local body
  if voice then
    body = voice.body
  elseif poll then
    body = poll.body
  else
    local text = present(text_in(r, 'message_text')) or text_in(r, 'caption')
    body = join({ present(document_of(r)) or photo_of(r), text }, ', ')
  end
  local notices = {}
  for _, info in ipairs(all_of(r, 'info', MAX_NOTICES)) do
    notices[#notices + 1] = clean(info.text)
  end
  local preview = preview_of(r, body == '')
  local other = (body == '' and preview == '') and bubble_text_of(r) or ''
  if body == '' and preview == '' and other == '' then
    return #notices > 0 and table.concat(notices, ', ') or nil
  end
  local status = first(r, 'status')
  local time = voice and voice.time or text_in(r, 'date')
  local state = voice and present(voice.state) or (status and status.contentDescription)
  local parts = table.pack(
    sender_of(r),
    present(body) or present(preview) or other,
    voice and elapsed_of(r),
    first(r, 'edit_label') and tr('edited'),
    body ~= '' and preview,
    reply_of(r),
    reactions_of(r),
    join({ time, state, text_in(r, 'conversation_row_date_divider') }, ', ')
  )
  for _, notice in ipairs(notices) do
    parts.n = parts.n + 1
    parts[parts.n] = notice
  end
  return join(parts, ', ')
end

local function read_more_in(r)
  for _, item in ipairs(r.items) do
    if item.contentDescription == 'Read more' then
      return item
    end
  end
end

local EXPAND_ATTEMPTS = 4
local EXPAND_DELAY = 250

-- Each focus is counted, so that a row read after focus moved on isn't said.
local focus_count = 0

-- WhatsApp cuts a long message off in the screen's text, so open it and say the whole message.
local function expand(row, list, read_more, count)
  read_more:click()
  local current = row
  for _ = 1, EXPAND_ATTEMPTS do
    sf.sleep(EXPAND_DELAY)
    current = current:refresh() or current
    if not current:find({ contentDescription = 'Read more' }) then
      break
    end
  end
  local text = describe(read_row(current, list))
  if text and count == focus_count then
    sf.speak(text, { interrupt = true })
  end
end

local expand_long = sf.settings.get('expandLong') ~= false
sf.onSettingChange(function(key, value)
  if key == 'expandLong' then
    expand_long = value ~= false
  end
end)

sf.onWindowChange(function()
  chats = {}
end)

-- Reads the focused row and says it, or what SandFly would have said, [fallback], if it isn't a
-- message.
local function say_row(item, fallback, count)
  local list = list_of(item)
  local r = list and read_row(item, list)
  local read_more = r and expand_long and read_more_in(r)
  if read_more then
    expand(item, list, read_more, count)
    return
  end
  local text = r and describe(r) or fallback
  if count == focus_count and present(text) then
    sf.speak(text, { interrupt = true })
  end
end

sf.onFocus(function(item, text)
  focus_count = focus_count + 1
  -- Only the id is looked at here, which needs no call to WhatsApp.
  if short_id(item):sub(1, 17) ~= 'conversation_row_' then
    return
  end
  sf.run(say_row, item, text, focus_count)
  return false
end)

local SKIPPED_BUTTONS = {
  name_in_group = true, contact_photo_view = true, url_layout = true, poll_option_vote_checkbox = true,
  info = true,
}

local function title_of(button)
  local id = short_id(button)
  if id == 'bubble_quoted_message_frame' then
    return tr('Go to replied message')
  elseif id == 'reactions_bubble_layout' then
    return tr('View reactions')
  elseif id == 'link_preview_frame' then
    return tr('Open link')
  elseif id == 'poll_option_main_layout' then
    return tr('Vote') .. ': ' .. label_of(button)
  elseif id == 'polls_main_layout' or id == 'image' then
    local label = label_of(button)
    return label:lower() == 'enlarge photo' and label or ''
  elseif id == 'control_btn' then
    return (button.className or ''):sub(-11) == 'ImageButton' and label_of(button) or tr('Download')
  elseif SKIPPED_BUTTONS[id] then
    return ''
  end
  local label = label_of(button)
  return label:find('^https?://') and tr('Open link') or label
end

sf.onActions(function(item)
  if not list_of(item) then
    return
  end
  local actions, titles = {}, {}
  for _, button in ipairs(item:findAll({ clickable = true }, MAX_BUTTONS)) do
    if button ~= item and not button:find('group_profile_initials') and not button:find('group_profile_pic') then
      local title = title_of(button)
      if title ~= '' and not titles[title] then
        titles[title] = true
        actions[#actions + 1] = { title = title, run = function() button:click() end }
      end
    end
  end
  return actions
end)
