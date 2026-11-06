-- Copyright 2026 papierek1997
-- Licensed under the Apache License, Version 2.0.
-- See the repository's LICENSE file.

local manifest = {
  id = 'local.ubereats.stable-restaurant-entry',
  name = 'Uber Eats: restaurant opening',
  author = 'papierek1997',
  version = '1.3',
  minApiVersion = 2,
  testedApiVersion = 3,
  apps = 'com.ubercab.eats',
  permissions = { 'java', 'screen', 'actions', 'input', 'speech', 'system' },
  description = 'Opens restaurants from search after leaving the active search view. Keeps the original restaurant link. Back from the restaurant returns to Account.',
  commands = {
    { id = 'open_restaurant', title = 'Open restaurant', gesture = 'doubleTap' },
  },
  settings = {
    { key = 'enabled', type = 'switch', title = 'Stable restaurant opening from search', default = true },
  },
}

local PACKAGE = 'com.ubercab.eats'
local Service = java.import('com.google.android.accessibility.talkback.TalkBackService')
local Uri = java.import('android.net.Uri')
local Log = java.import('android.util.Log')
local Configuration = java.import('android.content.res.Configuration')
local Locale = java.import('java.util.Locale')
local Array = java.import('java.lang.reflect.Array')
local service = Service:getInstance()
local busy = false
local accountLabelState

local function inUberEats()
  local app = sf.app()
  return app ~= nil and app.package == PACKAGE
end

local function searchRestaurantUrl()
  local node = service:findFocus(2)
  -- The focused text or picture may sit inside the restaurant's actual link.
  for _ = 1, 6 do
    if node == nil or tostring(node:getPackageName()) ~= PACKAGE then return nil end
    local value = node:getExtras():getString('AccessibilityNodeInfo.targetUrl')
    if value ~= nil then
      local url = tostring(value)
      local parsed = Uri:parse(url)
      if tostring(parsed:getScheme()) == 'ubereats'
          and tostring(parsed:getHost()) == 'store'
          and tostring(parsed:getPath()) == '/browse'
          and tostring(parsed:getQueryParameter('entrySource')) == 'GLOBAL_SEARCH'
          and parsed:getQueryParameter('storeUUID') ~= nil then
        local merchant = parsed:getQueryParameter('merchantType')
        if merchant == nil or tostring(merchant) == 'MERCHANT_TYPE_RESTAURANT' then
          return url
        end
      end
    end
    node = node:getParent()
  end
  return nil
end

local function addAccountLabel(state, value)
  if value == nil then return end
  local label = tostring(value)
  if label ~= '' and not state.seen[label] then
    state.seen[label] = true
    state.labels[#state.labels + 1] = label
  end
end

local function readAccountLabels(state, resources)
  for _, id in ipairs(state.ids) do addAccountLabel(state, resources:getString(id)) end
end

-- Loaded only for a restaurant activation that has reached the native tabs.
-- The normal path reads the current resources, without enumerating languages.
local function accountLabels()
  if accountLabelState ~= nil then return accountLabelState end
  local state = { labels = {}, seen = {}, ids = {}, expanded = false }
  local ok, reason = pcall(function()
    state.context = service:createPackageContext(PACKAGE, 0)
    state.resources = state.context:getResources()
    for _, name in ipairs({ 'identity_tab_account', 'accessibility_account' }) do
      local id = state.resources:getIdentifier(name, 'string', PACKAGE)
      if id ~= 0 then state.ids[#state.ids + 1] = id end
    end
    readAccountLabels(state, state.resources)
  end)
  if not ok then Log:w('UberEatsRoute', 'Cannot read Account labels: ' .. tostring(reason)) end
  -- Keep the previously supported layouts if the resources cannot be read.
  addAccountLabel(state, 'Account')
  addAccountLabel(state, 'Konto')
  accountLabelState = state
  return state
end

local function matchAccountTab(candidates, labels)
  for _, item in ipairs(candidates) do
    local description = item.contentDescription or ''
    for _, label in ipairs(labels) do
      if string.find(description, label, 1, true) then return item end
    end
  end
  return nil
end

local function localeTag(value)
  return tostring(value):gsub('^b%+', ''):gsub('%+', '-'):gsub('_', '-'):gsub('%-r(%u%u)', '-%1')
end

local function localeLanguage(tag)
  local language = tag:match('^([a-z][a-z][a-z]?)%-') or tag:match('^([a-z][a-z][a-z]?)$')
  return ({ iw = 'he', ['in'] = 'id', ji = 'yi' })[language] or language
end

-- Language splits identify the app translations actually installed. Android's
-- asset locale list can also include system languages, which need no reads.
local function installedLanguages(context)
  local ok, result = pcall(function()
    local splits = context:getPackageManager():getPackageInfo(PACKAGE, 0).splitNames
    local languages, any = {}, false
    if splits ~= nil then
      for i = 0, math.min(Array:getLength(splits), 128) - 1 do
        local tag = tostring(Array:get(splits, i)):match('^config%.(.+)$')
        local language = tag and localeLanguage(localeTag(tag))
        if language ~= nil then languages[language] = true; any = true end
      end
    end
    return any and languages or nil
  end)
  return ok and result or nil
end

local function translatedAccountTab(state, candidates)
  if state.expanded or state.resources == nil or #state.ids == 0 then return nil end
  state.expanded = true
  local ok, found = pcall(function()
    local languages = installedLanguages(state.context)
    local locales = state.resources:getAssets():getLocales()
    local seen, reads = {}, 0
    for i = 0, math.min(Array:getLength(locales), 256) - 1 do
      if not inUberEats() then error('App left the foreground') end
      local tag = localeTag(Array:get(locales, i))
      if tag ~= '' and not seen[tag] and (languages == nil or languages[localeLanguage(tag)]) then
        seen[tag] = true
        local configuration = java.new(Configuration, state.resources:getConfiguration())
        configuration:setLocale(Locale:forLanguageTag(tag))
        readAccountLabels(state, state.context:createConfigurationContext(configuration):getResources())
        local match = matchAccountTab(candidates, state.labels)
        if match ~= nil then return match end
        reads = reads + 1
        if reads % 8 == 0 then sf.sleep(1) end
      end
    end
    return nil
  end)
  if not ok then Log:w('UberEatsRoute', 'Cannot read other Account labels: ' .. tostring(found)) end
  return ok and found or nil
end

local function accountTab()
  -- The native navigation bar is a sibling of web content. Restrict the
  -- search to its Compose host, so a restaurant named "Account" is ignored.
  local hosts = sf.screen.findAll({
    className = 'UberComposeView', visible = true,
    inside = { id = 'ub__central_root_view' },
  }, 12)
  local candidates = {}
  for _, host in ipairs(hosts) do
    for _, item in ipairs(host:findAll({ visible = true }, 80)) do
      local description = item.contentDescription or ''
      if description ~= '' then candidates[#candidates + 1] = item end
    end
  end
  if #candidates == 0 then return nil end
  local state = accountLabels()
  return matchAccountTab(candidates, state.labels) or translatedAccountTab(state, candidates)
end

local function accountReady()
  local menu = sf.screen.find({ id = 'ub__identity_menu_view', visible = true })
  if menu == nil then return nil end
  -- Text views appear with the loaded native account content. Their actual
  -- words are irrelevant, and the loading placeholders are not text views.
  return menu:find({ className = 'TextView', visible = true })
end

local function waitForAccountTab()
  for _ = 1, 8 do
    if not inUberEats() then return nil end
    local tab = accountTab()
    if tab ~= nil then return tab end
    sf.sleep(100)
  end
  return nil
end

local function openOriginal(url)
  return sf.system.startActivity({
    action = 'android.intent.action.VIEW', data = url, package = PACKAGE,
  })
end

sf.onCommand('open_restaurant', function()
  if not sf.settings.get('enabled') then return false end
  if busy then return true end
  local captured, url = pcall(searchRestaurantUrl)
  if not captured or url == nil then return false end

  busy = true
  Log:i('UberEatsRoute', 'Captured restaurant link from search')
  local ok, reason = pcall(function()
    local tab = accountTab()
    for _ = 1, 3 do
      if tab ~= nil then break end
      if not inUberEats() then error('App left the foreground') end
      if not sf.system.back() then error('Cannot leave search') end
      tab = waitForAccountTab()
    end
    if tab == nil then error('Account tab unavailable') end
    if not inUberEats() then error('App left the foreground') end
    tab = tab:refresh()
    if tab == nil or not tab.visible then error('Account tab disappeared') end
    if not tab:tap() then error('Cannot switch to Account') end

    local ready
    for _ = 1, 15 do
      if not inUberEats() then error('App left the foreground') end
      ready = accountReady()
      if ready ~= nil then break end
      sf.sleep(100)
    end
    if ready == nil then error('Account screen unavailable') end
    ready:focus()
    Log:i('UberEatsRoute', 'Search detached; Account screen confirmed')
    if not openOriginal(url) then error('Cannot open restaurant') end
    Log:i('UberEatsRoute', 'Opened unchanged restaurant link')
  end)
  busy = false

  if not ok then
    Log:w('UberEatsRoute', 'Route normalization failed: ' .. tostring(reason))
    if inUberEats() then
      sf.message(sf._('Opening the restaurant normally.'))
      local fallbackOk, opened = pcall(openOriginal, url)
      if not fallbackOk or not opened then
        sf.message(sf._('Could not open the restaurant.'))
      end
    end
  end
  return true
end)

return manifest
