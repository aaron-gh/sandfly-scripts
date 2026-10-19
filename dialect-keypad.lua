local manifest = {
  id = 'dialect-keypad',
  name = 'Dialect keypad',
  version = '2.0',
  author = 'Aaron Hewitt',
  minApiVersion = 5,
  testedApiVersion = 5,
  description = 'Lifting the finger from a key on the Dialect keypad activates it: the digits, Backspace and Enter. Holding a digit or Backspace for the long-press hold time long-presses it.',
  apps = { 'com.dialect.launcher' },
  permissions = { 'speech' },
  settings = {
    {
      key = 'holdTime',
      type = 'list',
      title = 'Long-press hold time',
      default = '1000',
      options = {
        { value = '0', label = 'Off' },
        { value = '500', label = '0.5 seconds' },
        { value = '750', label = '0.75 seconds' },
        { value = '1000', label = '1 second' },
        { value = '1500', label = '1.5 seconds' },
        { value = '2000', label = '2 seconds' },
        { value = '3000', label = '3 seconds' },
      },
    },
  },
}

-- The letters on keys 2 to 9 follow Dialect's language: Latin, Cyrillic or Greek.
local ALPHABETS = {
  { 'ABC', 'DEF', 'GHI', 'JKL', 'MNO', 'PQRS', 'TUV', 'WXYZ' },
  { 'АБВГ', 'ДЕЁЖЗ', 'ИЙКЛ', 'МНОП', 'РСТУ', 'ФХЦЧ', 'ШЩЪЫ', 'ЬЭЮЯ' },
  { 'ΑΒΓ', 'ΔΕΖ', 'ΗΘΙ', 'ΚΛΜ', 'ΝΞΟ', 'ΠΡΣ', 'ΤΥΦ', 'ΧΨΩ' },
}

-- Backspace in each of Dialect's languages.
local BACKSPACE = { 'Backspace', 'Rücktaste', 'Retroceso', 'Retour arrière', 'Retrocesso', 'Стереть', 'Διαγραφή' }

-- Enter is named by the key and what it does, such as "Enter, calls Alex", so it's matched by the
-- start of each form in each language.
local ENTER = {
  'Enter, no matches to open', 'Enter, opens ', 'Enter, calls ', 'Enter, messages ',
  'Eingabetaste, keine Treffer zum Öffnen', 'Eingabetaste, öffnet ', 'Eingabetaste, ruft ', 'Eingabetaste, schreibt ',
  'Intro, no hay resultados que abrir', 'Intro, abre ', 'Intro, llama a ', 'Intro, envía un mensaje a ',
  'Entrée, aucun résultat à ouvrir', 'Entrée, ouvre ', 'Entrée, appelle ', 'Entrée, envoie un message à ',
  'Invio, nessun risultato da aprire', 'Invio, apre ', 'Invio, chiama ', 'Invio, invia un messaggio a ',
  'Enter, sem resultados para abrir', 'Enter, abre ', 'Enter, liga a ', 'Enter, envia mensagem a ',
  'Ввод, нет совпадений для открытия', 'Ввод, открывает ', 'Ввод, звонит ', 'Ввод, отправляет сообщение ',
  'Enter, καμία αντιστοίχιση για άνοιγμα', 'Enter, ανοίγει ', 'Enter, καλεί ', 'Enter, στέλνει μήνυμα σε ',
}

-- Digit keys are named by the digit and its letters: "2, A, B, C".
local digit_keys = { '0', '1' }
for _, alphabet in ipairs(ALPHABETS) do
  for at, key_letters in ipairs(alphabet) do
    local letters = {}
    for _, code in utf8.codes(key_letters) do
      letters[#letters + 1] = utf8.char(code)
    end
    digit_keys[#digit_keys + 1] = (at + 1) .. ', ' .. table.concat(letters, ', ')
  end
end

-- The typed number above the keypad is named by its digits too, but can't be clicked.
for _, name in ipairs(digit_keys) do
  sf.rules.add({ match = { contentDescription = name, clickable = true }, liftToActivate = true })
end
for _, name in ipairs(BACKSPACE) do
  sf.rules.add({ match = { contentDescription = name, clickable = true }, liftToActivate = true })
end
for _, start in ipairs(ENTER) do
  sf.rules.add({ match = { textContains = start, clickable = true }, liftToActivate = true })
end

-- longPressAfter only applies to items that lift to activate, so one rule covers every key. Enter
-- can't be long-pressed, so holding it and lifting presses it.
local hold_rule = nil
local function apply_hold_time()
  if hold_rule then
    sf.rules.remove(hold_rule)
  end
  local hold_time = tonumber(sf.settings.get('holdTime')) or 0
  hold_rule = hold_time > 0 and sf.rules.add({ match = { clickable = true }, longPressAfter = hold_time }) or nil
end

apply_hold_time()
sf.onSettingChange(function(key)
  if key == 'holdTime' then
    apply_hold_time()
  end
end)
