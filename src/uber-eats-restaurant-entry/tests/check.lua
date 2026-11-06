local translations = {
  en = 'Account', pl = 'Konto', de = 'Konto', fr = 'Compte',
  es = 'Cuenta', ar = 'الحساب', ja = 'アカウント', zh = '帳戶',
}
local original = 'ubereats://store/browse?storeUUID=fixture-store&entrySource=GLOBAL_SEARCH&entryActionValue=caf%C3%A9%26x&merchantType=MERCHANT_TYPE_RESTAURANT'
local cases = 0

local function environment(options)
  options = options or {}
  local state = { phase = 'navigation', opened = {}, messages = {}, actions = {}, resourceReads = 0,
    configurationReads = 0, localeListReads = 0, packageReads = 0, sleeps = 0, readLocales = {} }
  local deviceLanguage = options.deviceLanguage or 'pl'
  local appLanguage = options.appLanguage or deviceLanguage
  local app = 'com.ubercab.eats'
  local source = options.url or original
  local callback, onEnter
  local function javaArray(values)
    local result = { n = #values }
    for i, value in ipairs(values) do result[i - 1] = value end
    return result
  end
  local function resources(tag)
    return {
      getIdentifier = function(_, name)
        state.resourceReads = state.resourceReads + 1
        if options.missingResources then return 0 end
        return name == 'identity_tab_account' and 1 or 2
      end,
      getString = function() return translations[tag] or translations.en end,
      getConfiguration = function() return { tag = tag } end,
      getAssets = function()
        return { getLocales = function()
          state.localeListReads = state.localeListReads + 1
          return javaArray(options.locales or { 'af', 'am', 'az', 'bg', 'bn', 'en', 'pl', 'de', 'fr', 'es', 'ar', 'ja', 'zh' })
        end }
      end,
    }
  end
  local context = {
    getResources = function() return resources(deviceLanguage) end,
    createConfigurationContext = function(_, config)
      state.configurationReads = state.configurationReads + 1
      state.readLocales[#state.readLocales + 1] = config.tag
      return { getResources = function() return resources(config.tag) end }
    end,
    getPackageManager = function()
      return { getPackageInfo = function(_, package, flags)
        assert(package == app and flags == 0)
        state.packageReads = state.packageReads + 1
        return { splitNames = not options.monolithic and javaArray({ 'GooglePaySdk', 'config.arm64_v8a', 'config.pl', 'config.' .. appLanguage, 'config.xxhdpi' }) or nil }
      end }
    end,
  }
  local node = {
    getPackageName = function() return app end,
    getParent = function() return nil end,
    getExtras = function()
      if options.staleNode then error('node removed') end
      return { getString = function(_, key)
        assert(key == 'AccessibilityNodeInfo.targetUrl')
        return source
      end }
    end,
  }
  local service = {
    findFocus = function() return node end,
    createPackageContext = function(_, package)
      assert(package == app)
      return context
    end,
  }
  local account = {
    contentDescription = '⊙ ' .. translations[appLanguage] .. ' (1/5)',
    visible = true,
    tap = function()
      state.actions[#state.actions + 1] = 'account'
      state.phase = 'account'
      return true
    end,
  }
  account.refresh = function() return not options.staleTab and account or nil end
  local host = { findAll = function()
    return { { contentDescription = 'Search' }, account }
  end }
  local leaf = { focus = function()
    state.actions[#state.actions + 1] = 'native-focus'
    return true
  end }
  local menu = { find = function(_, query)
    assert(query.className == 'TextView' and query.visible)
    if options.loadingForever then return nil end
    return leaf
  end }
  local classes = {
    ['com.google.android.accessibility.talkback.TalkBackService'] = {
      getInstance = function() return service end,
    },
    ['android.net.Uri'] = { parse = function(_, url)
      return {
        getScheme = function() return url:match('^(.-)://') end,
        getHost = function() return url:match('^.-://([^/]+)') end,
        getPath = function() return url:match('^.-://[^/]+([^?]+)') end,
        getQueryParameter = function(_, key) return url:match('[?&]' .. key .. '=([^&]*)') end,
      }
    end },
    ['android.util.Log'] = { i = function() end, w = function() end },
    ['android.content.res.Configuration'] = { kind = 'configuration' },
    ['java.util.Locale'] = { forLanguageTag = function(_, tag) return tag end },
    ['java.lang.reflect.Array'] = {
      getLength = function(_, array) return array.n end,
      get = function(_, array, i) return array[i] end,
    },
  }
  local globals = {
    java = {
      import = function(name) return assert(classes[name], name) end,
      new = function(clazz, old)
        assert(clazz.kind == 'configuration')
        return { tag = old.tag, setLocale = function(self, tag) self.tag = tag end }
      end,
    },
    sf = {
      app = function() return { package = options.foreignApp and 'other.app' or app } end,
      settings = { get = function() return not options.disabled end },
      onAppEnter = function(fn) onEnter = fn end,
      onCommand = function(id, fn) assert(id == 'open_restaurant'); callback = fn end,
      sleep = function() state.sleeps = state.sleeps + 1 end,
      message = function(text) state.messages[#state.messages + 1] = text end,
      _ = function(text) return text end,
      screen = {
        findAll = function(query)
          assert(query.className == 'UberComposeView')
          assert(query.inside.id == 'ub__central_root_view')
          if options.foreignApp then return {} end
          return state.phase == 'navigation' and { host } or {}
        end,
        find = function(query)
          assert(query.id == 'ub__identity_menu_view')
          return state.phase == 'account' and menu or nil
        end,
      },
      system = {
        back = function() state.actions[#state.actions + 1] = 'back'; return true end,
        startActivity = function(intent)
          assert(intent.package == app and intent.action == 'android.intent.action.VIEW')
          state.opened[#state.opened + 1] = intent.data
          return not options.cannotOpen
        end,
      },
    },
  }
  setmetatable(globals, { __index = _G })
  local manifest = assert(load(script_source, 'main.lua', 't', globals))()
  assert(manifest.version == '1.3' and manifest.author == 'papierek1997')
  assert(manifest.id == 'local.ubereats.stable-restaurant-entry')
  assert(onEnter == nil, 'loading resources must not run on app entry')
  assert(state.resourceReads == 0 and state.configurationReads == 0, 'no resource work on load')
  return state, callback
end

for _, language in ipairs({ 'en', 'pl', 'de', 'fr', 'es', 'ar', 'ja', 'zh' }) do
  local state, run = environment({ appLanguage = language, deviceLanguage = 'pl' })
  assert(run())
  assert(#state.opened == 1 and state.opened[1] == original)
  assert(table.concat(state.actions, ',') == 'account,native-focus')
  assert(#state.messages == 0)
  if language == 'pl' or language == 'en' or language == 'de' then
    assert(state.configurationReads == 0 and state.localeListReads == 0 and state.packageReads == 0,
      'the common path must not enumerate languages or create locale configurations')
  else
    assert(state.configurationReads <= 2, 'read only installed app languages')
    for _, tag in ipairs(state.readLocales) do assert(tag == 'pl' or tag == language) end
  end
  local reads, configurations = state.resourceReads, state.configurationReads
  state.phase = 'navigation'
  assert(run() and #state.opened == 2)
  assert(state.resourceReads == reads and state.configurationReads == configurations,
    'the next restaurant activation must reuse resolved labels')
  cases = cases + 1
end

for _, options in ipairs({ { disabled = true }, { staleNode = true }, { foreignApp = true },
    { url = original:gsub('GLOBAL_SEARCH', 'FEED') },
    { url = original:gsub('MERCHANT_TYPE_RESTAURANT', 'MERCHANT_TYPE_GROCERY') },
    { url = original:gsub('ubereats://', 'https://') } }) do
  local state, run = environment(options)
  local handled = run()
  assert(#state.opened == 0 and #state.actions == 0)
  if not options.foreignApp then assert(not handled) end
  assert(state.resourceReads == 0 and state.configurationReads == 0)
  cases = cases + 1
end

do
  local state, run = environment({ cannotOpen = true })
  assert(run())
  assert(#state.opened == 2 and state.opened[1] == original and state.opened[2] == original)
  assert(state.messages[#state.messages] == 'Could not open the restaurant.')
  cases = cases + 1
end

do
  local state, run = environment({ loadingForever = true })
  assert(run())
  assert(#state.opened == 1 and state.opened[1] == original)
  assert(table.concat(state.actions, ',') == 'account')
  assert(state.messages[1] == 'Opening the restaurant normally.')
  cases = cases + 1
end

do
  local state, run = environment({ missingResources = true, appLanguage = 'pl' })
  assert(run() and #state.opened == 1)
  assert(table.concat(state.actions, ',') == 'account,native-focus')
  cases = cases + 1
end

do
  local state, run = environment({ staleTab = true })
  assert(run() and #state.opened == 1)
  assert(#state.actions == 0, 'a removed native tab must not be tapped by its old coordinates')
  assert(state.messages[1] == 'Opening the restaurant normally.')
  cases = cases + 1
end

do
  local state, run = environment({ appLanguage = 'zh', monolithic = true })
  assert(run() and #state.opened == 1)
  assert(state.sleeps >= 1, 'the monolithic fallback must yield during a long locale lookup')
  assert(table.concat(state.actions, ',') == 'account,native-focus')
  cases = cases + 1
end

return cases
