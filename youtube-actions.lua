-- YouTube video actions (Lua port of youtube-actions.js v1.6.1).
-- Skips the buttons inside each video, mix and playlist in YouTube lists, and puts them in its
-- Actions menu instead. Does the same for comments and replies.

local manifest = {
  id = 'youtube-actions',
  name = 'YouTube video actions',
  version = '1.6.1-lua',
  author = 'Surendra',
  minApiVersion = 1,
  testedApiVersion = 1,
  description = 'Skips the buttons inside each video, mix and playlist in YouTube lists, and puts them in its Actions menu instead. Does the same for comments and replies.',
  apps = { 'com.google.android.youtube', 'app.morphe.android.youtube' },
  permissions = { 'screen', 'actions', 'speech', 'input' },
  rules = {
    { match = { className = 'Button', inside = { clickable = true, textContains = 'play video' } }, hide = true },
    { match = { className = 'Button', inside = { clickable = true, textContains = 'play Short' } }, hide = true },
    { match = { className = 'Button', inside = { clickable = true, textContains = 'Mix - ' } }, hide = true },
    { match = { className = 'Button', contentDescription = 'Action menu', inside = { className = 'Button', clickable = true } }, hide = true },
    { id = 'contextual_menu_anchor', hide = true },
    { match = { className = 'Button', textContains = 'like this', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', contentDescription = 'Unlike', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', textContains = 'dislike', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', contentDescription = 'Reply', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', contentDescription = 'Action menu', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', textContains = 'repl', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', text = 'Read more', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', textContains = '@', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', textContains = '#', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', textContains = 'translate', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', textContains = 'see original', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
    { match = { className = 'Button', textContains = ':', inside = { id = 'engagement_panel_wrapper' } }, hide = true },
  },
}

-- YouTube ends each hashtag or link in a comment with an invisible joiner (U+2060), and the button
-- has no "#" in it. The manifest can only hold plain text, so this rule is added from code.
sf.rules.add({
  match = { className = 'Button', textContains = '\u{2060}', inside = { id = 'engagement_panel_wrapper' } },
  hide = true,
})

local MAX_BUTTONS = 8
local MAX_COMMENT_BUTTONS = 30

local function lower(text)
  return string.lower(text or '')
end

local function startsWith(text, prefix)
  return string.sub(text, 1, #prefix) == prefix
end

local function contains(text, part)
  return string.find(text, part, 1, true) ~= nil
end

local function trim(text)
  return (string.match(text, '^%s*(.-)%s*$'))
end

local function endsWithButton(item)
  return string.sub(item.className or '', -6) == 'Button'
end

local function isVideo(item)
  if not item.clickable then return false end
  local d = lower(item.contentDescription)
  return contains(d, 'play video') or contains(d, 'play short') or startsWith(d, 'mix - ')
end

-- "Action menu for <video title>" repeats the title the user just heard.
local function title(label)
  if startsWith(label, 'Action menu for') then return 'Action menu' end
  return (string.gsub(label, '[.:]+$', ''))
end

-- A comment or reply is the item that holds exactly one Reply button, which keeps its name whether the
-- comment is liked or not. A list of comments holds many.
local function isComment(item)
  if endsWithButton(item) then return false end
  return #item:findAll({ className = 'Button', contentDescription = 'Reply' }, 6) == 1
end

-- Removes the direction marks YouTube adds around names and text.
local function clean(text)
  text = text or ''
  local ok, result = pcall(function()
    local kept = {}
    for _, code in utf8.codes(text) do
      local mark = (code >= 0x200B and code <= 0x200F) or (code >= 0x202A and code <= 0x202E)
      if not mark then kept[#kept + 1] = utf8.char(code) end
    end
    return table.concat(kept)
  end)
  return trim(ok and result or text)
end

-- The name for a comment button, and where it goes in the menu.
local function commentAction(button)
  local description = clean(button.contentDescription)
  local text = clean(button.text)
  local label = description ~= '' and description or text
  if label == '' then return nil end
  local l = lower(label)
  if startsWith(l, 'like this') then return { rank = 0, title = 'Like' } end
  if l == 'unlike' then return { rank = 0, title = 'Unlike' } end
  if startsWith(l, 'dislike this') then return { rank = 1, title = 'Dislike' } end
  if contains(l, 'dislike') then return { rank = 1, title = label } end
  if l == 'reply' then return { rank = 2, title = 'Reply' } end
  if startsWith(l, 'action menu') then return { rank = 3, title = 'Action menu' } end
  if contains(l, 'reply') or contains(l, 'replies') then return { rank = 4, title = label } end
  if startsWith(description, '@') then return { rank = 5, title = 'Open profile ' .. description } end
  if l == 'read more' then return { rank = 6, title = 'Read more' } end
  if startsWith(l, 'translate') or startsWith(l, 'see original') then return { rank = 6.5, title = label } end
  if string.match(label, '^%d%d?:%d%d$') or string.match(label, '^%d%d?:%d%d:%d%d$') then
    return { rank = 7, title = 'Go to ' .. label }
  end
  -- A hashtag or link in the text: its name, without the invisible joiner.
  if not startsWith(label, '@') and (contains(label, '\u{2060}') or startsWith(label, '#')) then
    local name = string.gsub(string.gsub(label, '\u{2060}', ''), '#', '')
    return { rank = 8, title = 'Hashtag ' .. trim(name) }
  end
  if startsWith(label, '@') then return { rank = 9, title = 'Open ' .. label } end
  return { rank = 9, title = label }
end

local function commentActions(item)
  local seen = {}
  local found = {}
  for _, button in ipairs(item:findAll({ className = 'Button' }, MAX_COMMENT_BUTTONS)) do
    if button ~= item then
      local action = commentAction(button)
      if action and not seen[action.title] then
        seen[action.title] = true
        found[#found + 1] = { rank = action.rank, title = action.title, button = button, order = #found }
      end
    end
  end
  table.sort(found, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.order < b.order
  end)
  local actions = {}
  for _, a in ipairs(found) do
    actions[#actions + 1] = { title = a.title, run = function() a.button:click() end }
  end
  return actions
end

sf.onActions(function(item)
  local id = item.id or ''
  if string.sub(id, -15) == 'video_info_view' then
    local menu = item:find({ id = 'contextual_menu_anchor' })
    if menu then
      return { { title = 'Action menu', run = function() menu:click() end } }
    end
    return nil
  end
  if item.clickable and (isVideo(item) or endsWithButton(item)) then
    local actions = {}
    for _, button in ipairs(item:findAll({ className = 'Button' }, MAX_BUTTONS)) do
      local d = button.contentDescription
      if d and d ~= '' and button ~= item and not isVideo(button) then
        actions[#actions + 1] = { title = title(d), run = function() button:click() end }
      end
    end
    return actions
  end
  -- A comment or reply is not a video, so it is checked last.
  if isComment(item) then return commentActions(item) end
  return nil
end)
-- SandFly signature: MEUCIQDakzVaA+AOdDrO77a3BSTHqiuvOqSCOWtHCK1S3VSk0QIgVIUKaoVhx04vYH0agI39MFCUll0LmJU7fJbgJQVHsC4=
