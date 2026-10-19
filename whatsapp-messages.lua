local manifest = {
  id = 'whatsapp-messages',
  name = 'WhatsApp messages',
  version = '3.0',
  author = 'Aaron Hewitt',
  minApiVersion = 4,
  testedApiVersion = 5,
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

local MAX_BUTTONS = 24
local MAX_OPTIONS = 20
local LABEL_DEPTH = 3
local BUBBLE_DEPTH = 10
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

local function is_row(item)
  if short_id(item):sub(1, 17) ~= 'conversation_row_' then
    return false
  end
  local parent = item:parent()
  return parent ~= nil and (parent.id or ''):sub(-5) == '/list'
end

-- Removes the direction marks WhatsApp adds, U+200B to U+200F and U+202A to U+202E, and the "~"
-- before a name the contact list doesn't have.
local function clean(text)
  text = (text or ''):gsub('\226\128[\139-\143\170-\174]', '')
  text = text:gsub('^~%s*', '')
  return (text:match('^%s*(.-)%s*$'))
end

local function text_of(item, id)
  local found = item:find(id)
  return found and clean(found.text) or ''
end

local function main_of(row)
  return row:find('main_layout') or row:find('polls_main_layout')
end

-- Sent messages have a delivery status and sit against the right edge.
local function is_outgoing(row)
  if row:find('status') then
    return true
  end
  local main = main_of(row)
  return main ~= nil and row.bounds.right - main.bounds.right < main.bounds.left - row.bounds.left
end

-- In a chat with one person, the messages from them have no name and no picture.
local function contact_name(row)
  local list = row:parent()
  local is_group = not list
  if list then
    for _, id in ipairs({ 'name_in_group_tv', 'group_profile_pic', 'group_profile_initials' }) do
      if list:find(id) then
        is_group = true
        break
      end
    end
  end
  local title = not is_group and sf.screen.find('conversation_contact_name') or nil
  return title and clean(title.text) or ''
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
local function voice_of(row)
  local main = row:find('main_layout')
  local description = main and main.contentDescription or ''
  local voice_at = description:find(', voice message', 1, true)
  local audio_at = description:find(', audio message', 1, true)
  local at = voice_at and audio_at and math.min(voice_at, audio_at) or voice_at or audio_at
  if not at then
    return nil
  end
  local rest = description:sub(at + 2)
  local file = short_id(row) == 'conversation_row_audio' and text_of(row, 'description') or ''
  local body, time, state = split_time(rest)
  return {
    sender = clean(description:sub(1, at - 1)),
    body = join({ body or rest, file }, ', '),
    time = time or '',
    state = state or '',
  }
end

-- "Poll from Alex Smith, next event.\nSelect one or more\n..."; each option reads "Name, 2 votes".
local function poll_of(row)
  local main = row:find('polls_main_layout')
  if not main then
    return nil
  end
  local name = text_of(row, 'poll_name')
  local description = main.contentDescription or ''
  local end_at = description:find(', ' .. name .. '.', 1, true)
  local parts = { tr('poll') .. ': ' .. name, text_of(row, 'poll_type_text') }
  for _, option in ipairs(row:findAll({ id = 'poll_option_main_layout' }, MAX_OPTIONS)) do
    local label = clean(option.contentDescription)
    parts[#parts + 1] = option.checked and (tr('selected') .. ' ' .. label) or label
  end
  local prefix = 'Poll from '
  return {
    sender = description:sub(1, #prefix) == prefix and end_at and clean(description:sub(#prefix + 1, end_at - 1)) or '',
    body = join(parts, '. '),
  }
end

-- A message from the same sender as the one before it has no name of its own.
local function sender_of(row, depth)
  depth = depth or 3
  local named = text_of(row, 'name_in_group_tv')
  if named ~= '' then
    return named
  end
  local known = (voice_of(row) or poll_of(row) or {}).sender
  if present(known) then
    return known
  end
  if is_outgoing(row) then
    return tr('You')
  end
  local parent = row:parent()
  local siblings = parent and parent:children() or {}
  local previous
  for i, sibling in ipairs(siblings) do
    if sibling == row then
      previous = depth > 0 and i > 1 and siblings[i - 1] or nil
      break
    end
  end
  return previous and not is_outgoing(previous) and present(sender_of(previous, depth - 1)) or contact_name(row)
end

-- "Voice message, 2 minutes, 33 seconds elapsed"; "0 seconds elapsed" before it has played.
local function elapsed_of(row)
  local seek_bar = row:find('audio_seekbar')
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

local function document_of(row)
  if short_id(row) ~= 'conversation_row_document' then
    return ''
  end
  local content = row:find('content')
  local label = content and label_of(content) or ''
  return label ~= '' and (tr('document') .. ': ' .. label) or tr('document')
end

-- "Enlarge photo", or "Photo 331 kB" before it is downloaded.
local function photo_of(row)
  if short_id(row) ~= 'conversation_row_image' then
    return ''
  end
  local image = row:find('image')
  local label = clean(image and image.contentDescription)
  if label == '' or label:lower() == 'enlarge photo' then
    return tr('photo')
  end
  if label:sub(1, 5):lower() == 'photo' then
    return tr('photo') .. label:sub(6)
  end
  return label
end

local function reply_of(row)
  local holder = row:find('quoted_message_holder')
  if not holder then
    return ''
  end
  local author = text_of(holder, 'quoted_title')
  local quoted = text_of(holder, 'quoted_text')
  return join({ (tr('in reply to') .. ' ' .. author):match('^%s*(.-)%s*$'), quoted }, ': ')
end

-- A link's preview repeats the link; only a title that isn't the address is worth saying, unless
-- the message is only the link, which WhatsApp then shows as the preview alone.
local function preview_of(row, alone)
  local title = text_of(row, 'title')
  local is_address = title:find('^https?://') or title:find('^www%.')
  local named
  if title ~= '' and not is_address then
    named = title
  elseif alone then
    named = present(text_of(row, 'url')) or title
  end
  if not present(named) then
    return ''
  end
  return tr(row:find('play_button') and 'video link' or 'link') .. ': ' .. named
end

-- The time and status are said on their own, so a message of a kind not handled above is read
-- from the rest of the text in its bubble.
local SKIP_IDS = { date = true, status = true, name_in_group_tv = true, conversation_row_date_divider = true }
local function bubble_text_of(row)
  local texts, seen = {}, {}
  local visited = 0
  local function visit(item, depth)
    visited = visited + 1
    if SKIP_IDS[short_id(item)] or #texts >= MAX_BUBBLE_TEXTS or visited > MAX_BUBBLE_ITEMS then
      return
    end
    local own = clean(present(item.contentDescription) or item.text)
    if own ~= '' and not seen[own] then
      seen[own] = true
      texts[#texts + 1] = own
    end
    if depth > 0 then
      for _, child in ipairs(item:children()) do
        visit(child, depth - 1)
      end
    end
  end
  local main = main_of(row)
  if main then
    visit(main, BUBBLE_DEPTH)
  end
  return table.concat(texts, ', ')
end

local function reactions_of(row)
  local reactions = {}
  for _, reaction in ipairs(row:findAll({ id = 'reaction_bubble_emoji_text' }, 8)) do
    reactions[#reactions + 1] = clean(reaction.text)
  end
  if #reactions == 0 then
    return ''
  end
  return tr('reactions') .. ' ' .. table.concat(reactions, ' ')
end

local function describe(row)
  local voice = voice_of(row)
  local poll = not voice and poll_of(row) or nil
  local body
  if voice then
    body = voice.body
  elseif poll then
    body = poll.body
  else
    local text = present(text_of(row, 'message_text')) or text_of(row, 'caption')
    body = join({ present(document_of(row)) or photo_of(row), text }, ', ')
  end
  local notices = {}
  for _, info in ipairs(row:findAll({ id = 'info' }, 5)) do
    notices[#notices + 1] = clean(info.text)
  end
  local preview = preview_of(row, body == '')
  local other = (body == '' and preview == '') and bubble_text_of(row) or ''
  if body == '' and preview == '' and other == '' then
    return #notices > 0 and table.concat(notices, ', ') or nil
  end
  local status = row:find('status')
  local time = voice and voice.time or text_of(row, 'date')
  local state = voice and present(voice.state) or (status and status.contentDescription)
  local parts = table.pack(
    sender_of(row),
    present(body) or present(preview) or other,
    voice and elapsed_of(row),
    row:find('edit_label') and tr('edited'),
    body ~= '' and preview,
    reply_of(row),
    reactions_of(row),
    join({ time, state, text_of(row, 'conversation_row_date_divider') }, ', ')
  )
  for _, notice in ipairs(notices) do
    parts.n = parts.n + 1
    parts[parts.n] = notice
  end
  return join(parts, ', ')
end

local READ_MORE = { contentDescription = 'Read more' }
local EXPAND_ATTEMPTS = 4
local EXPAND_DELAY = 250

-- WhatsApp cuts a long message off in the screen's text, so open it and say the whole message.
local function expand(row, read_more)
  read_more:click()
  local current = row
  for _ = 1, EXPAND_ATTEMPTS do
    sf.sleep(EXPAND_DELAY)
    current = current:refresh() or current
    if not current:find(READ_MORE) then
      break
    end
  end
  local text = describe(current)
  if text then
    sf.speak(text, { interrupt = true })
  end
end

sf.onFocus(function(item)
  if not is_row(item) then
    return
  end
  local read_more = sf.settings.get('expandLong') ~= false and item:find(READ_MORE)
  if not read_more then
    return describe(item)
  end
  sf.run(expand, item, read_more)
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
  if not is_row(item) then
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
