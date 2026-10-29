-- Google Messages conversation actions (Lua port of google-messages-actions.js v1.0.0).
-- Adds Pin, Mark as unread, Archive, Delete, Snooze, Block and Add contact to the Actions menu of
-- each conversation in the Google Messages list.

local manifest = {
  id = 'google-messages-actions',
  name = 'Google Messages conversation actions',
  version = '1.0.0-lua',
  author = 'Surendra',
  minApiVersion = 1,
  testedApiVersion = 1,
  description = 'Adds Pin, Mark as unread, Archive, Delete, Snooze, Block and Add contact to the Actions menu of each conversation in the Google Messages list.',
  apps = { 'com.google.android.apps.messaging' },
  permissions = { 'screen', 'actions', 'speech', 'input' },
}

local ROW_ID = 'swipeableContainer'

local MORE = { { contentDescription = 'More options' } }
local DONE = { { id = 'action_mode_close_button' } }

-- "bar": a button in the toolbar that appears once the conversation is selected.
-- "menu": an entry in the More options popup, which is its own window.
local ACTIONS = {
  {
    title = 'Pin or unpin conversation',
    where = 'bar',
    queries = { { id = 'action_pin_to_top' }, { contentDescription = 'Unpin' }, { text = 'Unpin' } },
  },
  {
    title = 'Mark as unread or read',
    where = 'menu',
    queries = { { text = 'Mark as unread' }, { text = 'Mark as read' } },
  },
  {
    title = 'Archive conversation',
    where = 'bar',
    queries = { { id = 'action_archive' }, { contentDescription = 'Unarchive' } },
  },
  { title = 'Delete conversation', where = 'bar', queries = { { id = 'action_delete' } } },
  { title = 'Snooze notifications', where = 'bar', queries = { { id = 'action_snooze' } } },
  { title = 'Block', where = 'menu', queries = { { text = 'Block' } } },
  { title = 'Add contact', where = 'menu', queries = { { text = 'Add contact' } } },
}

local function shortId(item)
  return string.match(item.id or '', '[^/]*$')
end

-- A popup entry's text sits in a child; click the item that is clickable.
local function clickable(node)
  local current = node
  for _ = 1, 4 do
    if not current then break end
    if current.clickable then return current end
    current = current:parent()
  end
  return node
end

local function locate(queries)
  for _, query in ipairs(queries) do
    local found = sf.screen.find(query)
    if found then return clickable(found) end
  end
  return nil
end

local function waitFor(queries, tries)
  for _ = 1, tries or 8 do
    local found = locate(queries)
    if found then return found end
    sf.sleep(150)
  end
  return nil
end

-- Runs when an Actions menu entry is chosen. It can wait, so sf.sleep is allowed here.
local function perform(row, action)
  sf.sleep(400)
  if not row:longClick() then
    sf.speak('Could not select the conversation')
    return
  end
  local target = nil
  if action.where == 'bar' then
    target = waitFor(action.queries)
  else
    local more = waitFor(MORE)
    if more then
      more:click()
      target = waitFor(action.queries)
    end
  end
  if target then
    target:click()
    return
  end
  sf.speak(action.title .. ' is not available')
  -- Leave selection mode so the list works normally again.
  local done = locate(DONE)
  if done then done:click() end
end

sf.onActions(function(item)
  if shortId(item) ~= ROW_ID then return nil end
  local list = {}
  for _, action in ipairs(ACTIONS) do
    list[#list + 1] = { title = action.title, run = function() perform(item, action) end }
  end
  return list
end)
-- SandFly signature: MEQCICdCA9bTJKZn9AgFxm6tcqoYfB73rQ6LJ6L91BBKHoyzAiAX7JJVs8aRrnosCcU8DcN7gBlC7C9NN19JlEN9sUnpng==
