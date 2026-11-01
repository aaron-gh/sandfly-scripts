-- YouTube video actions (Lua port of youtube-actions.js v1.6.1).
-- Skips the items inside each video, mix, playlist, comment and reply in YouTube lists, and puts
-- them in its Actions menu instead.
-- The keyboard shortcuts of YouTube on the desktop control the player.

local manifest = {
  id = 'youtube-actions',
  name = 'YouTube video actions',
  version = '1.8.0-lua',
  author = 'Aaron Hewitt',
  minApiVersion = 2,
  testedApiVersion = 2,
  description = 'Skips the items inside each video, mix, playlist, comment and reply in YouTube lists, and puts them in its Actions menu instead. The keyboard shortcuts of YouTube on the desktop control the player: K, J, L, M, F, C, I, Shift+N, Shift+P and 0 to 9; and, with the player focused, Space, the arrow keys, Home and End.',
  apps = { 'com.google.android.youtube', 'app.morphe.android.youtube' },
  permissions = { 'screen', 'actions', 'speech', 'input', 'system' },
  commands = {
    { id = 'playPause', title = 'Play or pause', keys = 'k' },
    { id = 'playPauseFocused', title = 'Play or pause, with the player focused', keys = 'space' },
    { id = 'rewind', title = 'Rewind', keys = 'j' },
    { id = 'forward', title = 'Fast forward', keys = 'l' },
    { id = 'rewindFocused', title = 'Rewind, with the player focused', keys = 'left' },
    { id = 'forwardFocused', title = 'Fast forward, with the player focused', keys = 'right' },
    { id = 'volumeUp', title = 'Media volume up, with the player focused', keys = 'up' },
    { id = 'volumeDown', title = 'Media volume down, with the player focused', keys = 'down' },
    { id = 'mute', title = 'Mute or unmute media volume', keys = 'm' },
    { id = 'fullscreen', title = 'Full screen', keys = 'f' },
    { id = 'captions', title = 'Captions', keys = 'c' },
    { id = 'next', title = 'Next video', keys = 'shift+n' },
    { id = 'previous', title = 'Previous video', keys = 'shift+p' },
    { id = 'miniplayer', title = 'Miniplayer', keys = 'i' },
    { id = 'start', title = 'Go to the start, with the player focused', keys = 'home' },
    { id = 'finish', title = 'Go to the end, with the player focused', keys = 'end' },
    { id = 'seek0', title = 'Go to 0%', keys = '0' },
    { id = 'seek1', title = 'Go to 10%', keys = '1' },
    { id = 'seek2', title = 'Go to 20%', keys = '2' },
    { id = 'seek3', title = 'Go to 30%', keys = '3' },
    { id = 'seek4', title = 'Go to 40%', keys = '4' },
    { id = 'seek5', title = 'Go to 50%', keys = '5' },
    { id = 'seek6', title = 'Go to 60%', keys = '6' },
    { id = 'seek7', title = 'Go to 70%', keys = '7' },
    { id = 'seek8', title = 'Go to 80%', keys = '8' },
    { id = 'seek9', title = 'Go to 90%', keys = '9' },
  },
  rules = {
    -- Everything that can be clicked inside a video, mix, playlist, comment or reply in a list.
    -- The rows themselves are not inside a clickable item, so they stay.
    { match = { clickable = true, inside = { { clickable = true }, { id = 'results' } } }, hide = true },
    { match = { clickable = true, inside = { { clickable = true }, { id = 'section_list' } } }, hide = true },
    -- On phones, the items of a video, mix or Short sit side by side in a row that can't be clicked.
    -- The row is read as one item, and a double-tap presses its first clickable item, which opens
    -- the video. In a row with a heading, such as a shelf's title, a double-tap presses nothing.
    { match = { focusable = true, clickable = false, scrollable = false, inside = { id = 'results' }, has = { heading = true } }, group = true, activate = { heading = true } },
    { match = { focusable = true, clickable = false, scrollable = false, inside = { id = 'section_list' }, has = { heading = true } }, group = true, activate = { heading = true } },
    { match = { focusable = true, clickable = false, scrollable = false, inside = { id = 'results' }, has = { clickable = true } }, group = true, activate = { clickable = true } },
    { match = { focusable = true, clickable = false, scrollable = false, inside = { id = 'section_list' }, has = { clickable = true } }, group = true, activate = { clickable = true } },
    { id = 'contextual_menu_anchor', hide = true },
  },
}

-- Items are found by their view ids and by where they are, never by their text, so the script works
-- in every language. Menu entries are named with the text YouTube gives each item.

-- The lists whose rows hold other items: feeds, search results, comments and replies.
local LISTS = { results = true, section_list = true }
local MAX_ROW_ACTIONS = 30
local MAX_ROW_ITEMS = 100

local function shortId(item)
  return string.match(item.id or '', '[^/]*$')
end

local function trim(text)
  return (string.match(text, '^%s*(.-)%s*$'))
end

-- Removes the direction marks YouTube adds around names and text, and the invisible joiner (U+2060)
-- at the end of each hashtag or link.
local function clean(text)
  text = text or ''
  local ok, result = pcall(function()
    local kept = {}
    for _, code in utf8.codes(text) do
      local mark = (code >= 0x200B and code <= 0x200F) or (code >= 0x202A and code <= 0x202E) or code == 0x2060
      if not mark then kept[#kept + 1] = utf8.char(code) end
    end
    return table.concat(kept)
  end)
  return trim(ok and result or text)
end

local function label(item)
  local description = clean(item.contentDescription)
  if description ~= '' then return description end
  return clean(item.text)
end

local function inList(item)
  local node = item:parent()
  for _ = 1, 30 do
    if not node then return false end
    if LISTS[shortId(node)] then return true end
    node = node:parent()
  end
  return false
end

-- A row that the rules read as one item: one that can't be clicked, with clickable items in it.
local function isSideBySideRow(item)
  return not item.clickable and item.focusable and not item.scrollable and inList(item)
    and item:find({ clickable = true }) ~= nil
end

-- A row is a clickable item in one of the lists, and not inside another clickable item, or a row
-- read as one item.
local function isRow(item)
  if not item.clickable then return isSideBySideRow(item) end
  local node = item:parent()
  for _ = 1, 30 do
    if not node then return false end
    if LISTS[shortId(node)] then return true end
    if node.clickable then return false end
    node = node:parent()
  end
  return false
end

-- The item a double-tap presses in a row read as one item, as the rules set it: none in a row with
-- a heading, and otherwise its first clickable item. items is everything in the row, row first.
local function pressedItem(items)
  local first
  for i = 2, #items do
    if items[i].heading then return nil end
    if not first and items[i].clickable then first = items[i] end
  end
  return first
end

-- The clickable items inside a row, other than the one a double-tap presses. Items in a group of
-- their own, such as Like, Dislike and Reply of a comment, come first. A group without a name of
-- its own is left out.
local function rowActions(row)
  local pressed = not row.clickable and pressedItem(row:findAll({}, MAX_ROW_ITEMS)) or nil
  local grouped, others, seen = {}, {}, {}
  for _, inner in ipairs(row:findAll({ clickable = true }, MAX_ROW_ACTIONS)) do
    local title = (inner ~= row and inner ~= pressed) and label(inner) or ''
    if title ~= '' and not seen[title] then
      seen[title] = true
      local parent = inner:parent()
      local list = (parent and parent ~= row and parent.clickable) and grouped or others
      list[#list + 1] = { title = title, run = function() inner:click() end }
    end
  end
  for _, action in ipairs(others) do
    grouped[#grouped + 1] = action
  end
  return grouped
end

-- What a row read as one item says: the name of the item a double-tap presses, and the text in the
-- row that can't be clicked. Text already said, such as the channel in a video's name, is left out.
local function rowText(row)
  local items = row:findAll({}, MAX_ROW_ITEMS)
  local pressed = pressedItem(items)
  local parts = {}
  for i = 2, #items do
    local inner = items[i]
    local text = (inner == pressed or not inner.clickable) and label(inner) or ''
    local said = text == ''
    for _, part in ipairs(parts) do
      if string.find(part, text, 1, true) then
        said = true
        break
      end
    end
    if not said then parts[#parts + 1] = text end
  end
  return table.concat(parts, ', ')
end

-- Each focus is counted, so that a row read after focus moved on isn't said.
local focusCount = 0

-- Reads the focused row and says it, or what SandFly would have said, fallback, if it isn't a row.
local function sayRow(item, fallback, count)
  local text = isSideBySideRow(item) and rowText(item) or ''
  if text == '' then text = fallback or '' end
  if count == focusCount and text ~= '' then
    sf.speak(text, { interrupt = true })
  end
end

-- Finding the row's items asks YouTube for each of them, which takes longer than the 30
-- milliseconds SandFly waits for onFocus, so the row is read after onFocus returns. Only fields of
-- the item itself are looked at here, which need no call to YouTube.
sf.onFocus(function(item, text)
  focusCount = focusCount + 1
  if item.clickable or not item.focusable or item.scrollable or (item.childCount or 0) == 0
      or label(item) ~= '' then
    return
  end
  sf.setTimeout(sayRow, 0, item, text, focusCount)
  return false
end)

sf.onActions(function(item)
  if shortId(item) == 'video_info_view' then
    local menu = item:find({ id = 'contextual_menu_anchor' })
    if menu and label(menu) ~= '' then
      return { { title = label(menu), run = function() menu:click() end } }
    end
    return nil
  end
  if not isRow(item) then return nil end
  local actions = rowActions(item)
  if #actions == 0 then return nil end
  return actions
end)

-- Keyboard shortcuts. The player's controls are found by their view ids, which are the same in
-- every language.

-- The video player, on the watch page and as the miniplayer. Clicking it shows or hides the controls.
local PLAYER = 'watch_player'
local PLAY_PAUSE = { 'player_control_play_pause_replay_button', 'floaty_play_pause_button', 'modern_miniplayer_overlay_action_button' }
local REWIND = { 'player_control_rewind_button', 'modern_miniplayer_rewind_button' }
local FORWARD = { 'player_control_fast_forward_button', 'modern_miniplayer_forward_button' }
local NEXT = { 'player_control_next_button' }
local PREVIOUS = { 'player_control_previous_button' }
local FULLSCREEN = { 'fullscreen_button' }
local CAPTIONS = { 'player_subtitle_button' }
local COLLAPSE = { 'player_collapse_button' }
local EXPAND = { 'modern_miniplayer_expand' }
local MINIPLAYER = { 'floaty_play_pause_button', 'modern_miniplayer_close' }

-- Where the seek bar is: below the player on the watch page, and in the miniplayer. The seek bar has
-- no view id of its own there. Each scroll action moves it by a twentieth of the video.
local SEEK_BARS = { 'watch_while_time_bar_view', 'floaty_bar_time_bar_view', PLAYER }
local SEEK_STEPS = 20

local function visibleItem(id)
  local item = sf.screen.find({ id = id })
  if item and item.visible then return item end
  return nil
end

local function first(ids)
  for _, id in ipairs(ids) do
    local item = visibleItem(id)
    if item then return item end
  end
  return nil
end

local function player()
  return visibleItem(PLAYER)
end

local function inMiniplayer()
  return first(MINIPLAYER) ~= nil
end

local function isSeekBar(item)
  return string.sub(item.className or '', -7) == 'SeekBar'
end

local function seekBar()
  for _, id in ipairs(SEEK_BARS) do
    local holder = visibleItem(id)
    local bar = holder and (isSeekBar(holder) and holder or holder:find({ className = 'SeekBar' }))
    if bar and bar.visible then return bar end
  end
  return nil
end

-- Whether SandFly's focus is on the player, one of its controls or the seek bar.
local function focusInPlayer(event)
  local node = event.node or sf.screen.focused()
  for _ = 1, 30 do
    if not node then return false end
    local id = shortId(node)
    if id == PLAYER or id == SEEK_BARS[1] or id == SEEK_BARS[2] then return true end
    node = node:parent()
  end
  return false
end

-- Clicking the miniplayer opens the watch page, so its controls are not shown this way.
local function showControls()
  if inMiniplayer() or first(PLAY_PAUSE) then return end
  local view = player()
  if view then view:click() end
end

-- The item from find, showing the controls first if it isn't on screen.
local function control(find)
  local item = find()
  if item then return item end
  showControls()
  local deadline = sf.clock() + 1000
  repeat
    sf.sleep(100)
    item = find()
    if item then return item end
  until sf.clock() >= deadline
  return nil
end

local function press(ids)
  local item = control(function() return first(ids) end)
  if item then
    item:click()
  else
    sf.playSound('beep')
  end
end

local function step(bar, forward, count)
  for _ = 1, count do
    if forward then bar:scrollForward() else bar:scrollBackward() end
  end
end

-- Goes to the start, then forward by tenths of the video.
local function seekTo(tenths)
  local bar = control(seekBar)
  if not bar then
    sf.playSound('beep')
    return
  end
  step(bar, false, SEEK_STEPS)
  step(bar, true, tenths * SEEK_STEPS // 10)
end

local function goToEnd()
  local bar = control(seekBar)
  if bar then
    step(bar, true, SEEK_STEPS)
  else
    sf.playSound('beep')
  end
end

local function sayVolume(level, volume)
  local percent = math.floor((level - volume.min) * 100 / (volume.max - volume.min) + 0.5)
  sf.speak(percent .. '%', { interrupt = true })
end

-- Desktop YouTube changes the volume by 5%.
local function changeVolume(direction)
  local volume = sf.device.volume('media')
  local amount = math.max(1, math.floor((volume.max - volume.min) / 20 + 0.5))
  local level = math.min(volume.max, math.max(volume.min, volume.level + direction * amount))
  sf.device.setVolume('media', level)
  sayVolume(level, volume)
end

local function toggleMute()
  local volume = sf.device.volume('media')
  local level = volume.min
  if volume.level > volume.min then
    sf.storage.set('unmuteLevel', volume.level)
  else
    level = sf.storage.get('unmuteLevel', (volume.min + volume.max) // 2)
  end
  sf.device.setVolume('media', level)
  sayVolume(level, volume)
end

local function toggleMiniplayer()
  if not inMiniplayer() then
    press(COLLAPSE)
    return
  end
  local expand = first(EXPAND)
  local target = expand or player()
  if target then target:click() end
end

-- A held key runs its command again. Commands that toggle run once per press: a run within this
-- many milliseconds of the last is skipped.
local REPEAT_MS = 600
local lastRun = {}

-- A key does something only while a video player is on screen, and keys marked focused only while
-- SandFly's focus is in the player. Otherwise the app gets the key. SandFly passes the key on only
-- if false comes back within 30 milliseconds, so focused keys check the focus alone.
local function onKey(id, run, options)
  options = options or {}
  sf.onCommand(id, function(event)
    if options.focused then
      if not focusInPlayer(event) then return false end
    elseif not player() then
      return false
    end
    if not options.repeats then
      local now = sf.clock()
      local last = lastRun[id]
      lastRun[id] = now
      if last and now - last < REPEAT_MS then return end
    end
    run()
  end)
end

local FOCUSED = { focused = true }
local REPEATS = { repeats = true }
local FOCUSED_REPEATS = { focused = true, repeats = true }

onKey('playPause', function() press(PLAY_PAUSE) end)
onKey('playPauseFocused', function() press(PLAY_PAUSE) end, FOCUSED)
onKey('rewind', function() press(REWIND) end, REPEATS)
onKey('forward', function() press(FORWARD) end, REPEATS)
onKey('rewindFocused', function() press(REWIND) end, FOCUSED_REPEATS)
onKey('forwardFocused', function() press(FORWARD) end, FOCUSED_REPEATS)
onKey('volumeUp', function() changeVolume(1) end, FOCUSED_REPEATS)
onKey('volumeDown', function() changeVolume(-1) end, FOCUSED_REPEATS)
onKey('mute', toggleMute)
onKey('fullscreen', function() press(FULLSCREEN) end)
onKey('captions', function() press(CAPTIONS) end)
onKey('next', function() press(NEXT) end)
onKey('previous', function() press(PREVIOUS) end)
onKey('miniplayer', toggleMiniplayer)
onKey('start', function() seekTo(0) end, FOCUSED)
onKey('finish', goToEnd, FOCUSED)
for tenths = 0, 9 do
  onKey('seek' .. tenths, function() seekTo(tenths) end)
end
-- SandFly signature: MEYCIQDgKhGH51nrvh1h0sEPmwD76rlg36o3vrGsEPIBpO71wQIhALhSY583CwoQbkQUx/C5Mkl99ybPB7kqzES11hRLOCqO
