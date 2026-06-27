--[[
  SAES Callout System v2 — MoonLoader + mimgui
  Copyright (C) 2026 SAES_sexorcist

  Эта программа — свободное ПО: вы можете распространять и/или изменять её
  на условиях GNU General Public License версии 3, опубликованной
  Free Software Foundation.

  Распространяется в надежде на пользу, но БЕЗ КАКИХ-ЛИБО ГАРАНТИЙ.
  Подробности — в GNU GPL: <https://www.gnu.org/licenses/>.
  -----------------------------------------------
  Requires (all standard in MoonLoader):
    mimgui, encoding, dkjson, socket.http, ltn12

  Опционально (для иконок):
    fAwesome6_solid  →  moonloader/lib/fAwesome6_solid.lua

  Commands: /callout  /911  /sos
]]

--@PLAIN-BEGIN  (метаданные + effil-воркер: уходят в дистрибутив БЕЗ обфускации)
-- script_name/version держим литералами в плейн-части: апдейтер валидирует скачанный
-- файл по подстроке 'SAES Callout System', а Prometheus зашифровал бы её в core.
script_name("SAES Callout System")
script_author("SAES_sexorcist")
script_version("2.0.4")

-- HTTP-воркер для effil.thread: чистая функция без апвелью. effil переносит её в
-- отдельный OS-поток через string.dump; обфускация добавила бы апвелью на дешифратор
-- строк и сломала бы перенос — поэтому модуль остаётся плейн (require-строка в core
-- линкует его с обфусцированным телом, переживая шифрование как обычная строка).
package.preload['saes_callout.httpworker'] = function()
  return function(method, url, auth, ct, cl, body, ver)
    local http  = require('socket.http')
    local ltn12 = require('ltn12')
    http.TIMEOUT = 5
    local hdrs  = { ['Connection'] = 'close' }
    if auth then hdrs['Authorization']   = auth end
    if ct   then hdrs['Content-Type']    = ct   end
    if cl   then hdrs['Content-Length']  = cl   end
    if ver  then hdrs['X-Script-Version'] = ver end
    local chunks = {}
    local ok_req, code = http.request({
      method  = method,
      url     = url,
      headers = hdrs,
      source  = body and ltn12.source.string(body) or nil,
      sink    = ltn12.sink.table(chunks),
    })
    return (ok_req ~= nil), (code or 0), table.concat(chunks)
  end
end
--@PLAIN-END

-- Версия для рантайма (чат/проверка обновлений). ДОЛЖНА совпадать со script_version
-- в плейн-блоке выше — build/split.py проверяет это и падает при расхождении.
local VERSION = "2.0.4"

-- ═══════════════════════════════════════════════════════════
--  ЗАВИСИМОСТИ
-- ═══════════════════════════════════════════════════════════

local imgui    = require 'mimgui'
local ffi      = require 'ffi'
local json     = require 'dkjson'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local ok_ti, ti  = pcall(require, 'tabler_icons')
local ok_lfs, lfs = pcall(require, 'lfs')

-- Font Awesome 6 иконки (опционально — работает и без него)
local ok_fa, fa = pcall(require, 'fAwesome6_solid')
local effil     = require('effil')
-- Плейн effil-воркер из package.preload (см. --@PLAIN-BEGIN). require-строка переживает
-- обфускацию, а сам воркер остаётся незашифрованным → string.dump в OS-поток не падает.
local httpWorker = require('saes_callout.httpworker')

-- Звуковой сигнал оповещений: mp3 из resource/sounds (через аудио-API MoonLoader).
-- Если файла/потока нет — просто тишина (без системного звука).
local snd_handle = nil
local notify_vol = 0.7   -- громкость оповещений 0.0..1.0 (настраивается в настройках)
-- Применить текущую громкость к уже загруженному потоку (живой предпросмотр в настройках)
local function applyNotifyVolume()
  if snd_handle then pcall(function() setAudioStreamVolume(snd_handle, notify_vol) end) end
end
local function playNotifySound()
  local path = getWorkingDirectory() .. '/resource/sounds/notify.mp3'
  if not snd_handle and doesFileExist(path) then
    pcall(function() snd_handle = loadAudioStream(path) end)
  end
  if snd_handle then
    -- громкость + stop→play, чтобы каждый раз проигрывать с начала
    pcall(function()
      setAudioStreamVolume(snd_handle, notify_vol)
      setAudioStreamState(snd_handle, 0)
      setAudioStreamState(snd_handle, 1)
    end)
  end
end

-- ═══════════════════════════════════════════════════════════
--  КОНФИГ
-- ═══════════════════════════════════════════════════════════

local CFG = {
  bot_url      = "http://138.68.99.152:3001",
  discord_url  = "https://discord.gg/ZqWWQ2Ypfa",
  commands     = { "callout", "911" },
  cfg_file     = getWorkingDirectory() .. "/config/saes_callout.ini",
  W = 520,
  H = 620,
  -- Публичный репозиторий раздачи скрипта (для проверки версии и автообновления)
  gh_owner  = "sexorcist00",
  gh_repo   = "saes-ingame-callout",
  gh_branch = "main",
}
CFG.version_url = ("https://raw.githubusercontent.com/%s/%s/%s/version.json"):format(CFG.gh_owner, CFG.gh_repo, CFG.gh_branch)
CFG.repo_url    = ("https://github.com/%s/%s"):format(CFG.gh_owner, CFG.gh_repo)
-- База для raw-файлов внутри moonloader/ (ресурсы синхронизируются авто-апдейтером)
CFG.raw_base    = ("https://raw.githubusercontent.com/%s/%s/%s/moonloader/"):format(CFG.gh_owner, CFG.gh_repo, CFG.gh_branch)

-- ═══════════════════════════════════════════════════════════
--  СОСТОЯНИЕ
-- ═══════════════════════════════════════════════════════════

local visible   = imgui.new.bool(false)
local screen    = 'token'   -- token | subdivisions | callout | success | settings | update

-- Состояние проверки обновлений
local upd = {
  available = false,   -- доступна новее версия (latest > VERSION)
  required  = false,   -- текущая версия < min_supported → обязательное обновление
  latest    = nil,
  changelog = nil,
  dl_url    = nil,     -- прямая ссылка на новый .lua (из version.json)
  busy      = false,   -- идёт автообновление
  status    = nil,     -- текст статуса для экрана обновления
}
local auth       = nil
local nick       = nil
local local_nick = nil  -- SAMP ник до авторизации, кэшируется в main()
local subs          = {}
local subs_fetched_at = 0   -- os.clock() последней успешной загрузки списка (TTL-кэш)
local SUBS_TTL        = 30  -- сек: чаще этого список не перезапрашивается
local factions_list = {}   -- [{id, name, logo_url, description, subs=[]}]
local sub_view      = 'factions'  -- 'factions' | 'detail'
local faction_page  = 1
local sel_faction   = nil  -- выбранная фракция
local sel_id        = nil
local cid           = nil
local success_at    = nil  -- os.clock() начала авто-таймера закрытия на экране успеха
local SUCCESS_CLOSE_SEC = 4  -- через сколько секунд экран успеха закроется сам
local loading          = false
local err_msg          = nil
local show_auth        = false
local prev_screen      = 'token'
local fact_textures    = {}   -- url -> texture
local fact_tex_loading = {}   -- url -> bool
local fact_tex_queue   = {}   -- {url, path} ожидают CreateTextureFromFile в render thread
local hotkey_vk       = 0
local close_hotkey_vk = 0    -- горячая клавиша закрытия окна на экране успеха
local http_queue      = {}   -- единая очередь HTTP; обрабатывается по одному в main loop
local http_in_flight  = false
local user_avatar_url  = nil  -- Discord CDN URL аватара (nil = ещё не получен/ошибка, string = есть)
local avatar_fetching  = false -- запрос /me за аватаром сейчас в полёте
local av_hover_scale   = 1.0  -- плавный scale аватара при наведении
local fetchUserAvatar        -- forward-declaration; определяется после loadTextureFromUrl
local waiting_key  = false  -- false | 'open' | 'close' — какую клавишу сейчас захватываем

-- ─── Размеры окон (ресайз пользователем + сохранение в конфиг) ─
local win_sizes        = {}    -- screen -> { w=, h= } (сохраняется между запусками)
local win_size_dirty   = false -- размер менялся, нужно сохранить
local win_size_saved_at = 0    -- os.clock() последнего сохранения (дебаунс)
-- Версия схемы размеров. При изменении дефолтов поднимаем число — старые
-- сохранённые размеры один раз сбрасываются, чтобы применился новый дефолт.
local LAYOUT_VER       = 2

-- Дефолтные и минимальные размеры по экранам. Максимум считается от разрешения экрана.
-- h = 0 → авто-подгон высоты под контент при первом показе (модальные экраны),
-- дальше окно остаётся свободно ресайзимым.
local WIN_DEF = {
  token        = { w = 420, h = 0 },
  subdivisions = { w = 520, h = 760 },  -- вмещает ~3 фракции даже с панелью активных каллаутов
  callout      = { w = 520, h = 510 },
  callout_card = { w = 520, h = 600 },
  success      = { w = 380, h = 0 },
  settings     = { w = 420, h = 480 },  -- стартовая высота; точный минимум меряется в рантайме
  update       = { w = 440, h = 0 },
}
local WIN_MIN = {
  token        = { w = 360, h = 200 },
  subdivisions = { w = 460, h = 380 },
  callout      = { w = 460, h = 420 },
  callout_card = { w = 460, h = 400 },
  success      = { w = 320, h = 180 },
  settings     = { w = 360, h = 240 },
  update       = { w = 380, h = 200 },
}

-- ─── Активные каллауты (тянутся с сервера: автор = привязанный аккаунт) ────
local active_callouts = {}    -- { id, faction_name, faction_logo_url, brief, description,
                              --   location, tac, subdivision_name, created_at(os.time),
                              --   status('pending'|...), detail(ответ сервера) }
local sel_callout     = nil   -- выбранный каллаут для полной карточки
local AC_INTERVAL      = 30   -- сек: интервал автообновления в простое (список пуст)
local AC_INTERVAL_ACTIVE = 10 -- сек: чаще, когда есть каллауты — следим за сменой статуса
local AC_INTERVAL_BG   = 12   -- сек: фоновый опрос при ЗАКРЫТОМ меню (пока есть что отслеживать)

-- ─── Оповещения (тосты поверх игры, в т.ч. при свёрнутом меню) ──
local toasts          = {}    -- { id, name, brief, logo_url, born(os.clock) }
local TOAST_DUR       = 6.0   -- сек видимости тоста
local TOAST_ANIM      = 0.32  -- сек слайд-ин/аут
local ac_prev_status  = {}    -- [id] = последний known derived_status (детект переходов)
local ac_primed       = false -- первый фетч — только базлайн, без оповещений
local ac_fetch_at     = 0     -- os.clock() последнего запроса списка
local ac_fetching     = false -- запрос списка сейчас в полёте
local fetchActiveCallouts     -- forward-declaration; определяется после loadTextureFromUrl

-- Метаданные производного статуса каллаута: подпись + цвет бейджа
local STATUS_META = {
  pending   = { label = 'Ожидает',  r = 0.62, g = 0.62, b = 0.65 },
  accepted  = { label = 'Принят',   r = 0.35, g = 0.78, b = 0.42 },
  declined  = { label = 'Отклонён', r = 0.92, g = 0.32, b = 0.32 },
  closed    = { label = 'Закрыт',   r = 0.45, g = 0.45, b = 0.48 },
  cancelled = { label = 'Отменён',  r = 0.45, g = 0.45, b = 0.48 },
}
local function statusMeta(s) return STATUS_META[s] or STATUS_META.pending end

-- Длительность в коротком виде: «42с», «12м», «1ч 5м»
local function fmtDuration(sec)
  sec = math.max(0, math.floor(sec))
  if sec < 60 then return sec .. 'с' end
  local m = math.floor(sec / 60)
  if m < 60 then return m .. 'м' end
  local h = math.floor(m / 60)
  return h .. 'ч ' .. (m % 60) .. 'м'
end

-- Русское склонение числительных: plural(2,'час','часа','часов') → 'часа'
local function plural(n, one, few, many)
  local n10, n100 = n % 10, n % 100
  if n100 >= 11 and n100 <= 14 then return many end
  if n10 == 1 then return one end
  if n10 >= 2 and n10 <= 4 then return few end
  return many
end

-- «X назад» с секундами (живой счётчик): «20 минут 5 секунд назад»
local function fmtAgo(sec)
  sec = math.max(0, math.floor(sec))
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  local parts = {}
  if h > 0 then parts[#parts + 1] = h .. ' ' .. plural(h, 'час', 'часа', 'часов') end
  if m > 0 then parts[#parts + 1] = m .. ' ' .. plural(m, 'минута', 'минуты', 'минут') end
  parts[#parts + 1] = s .. ' ' .. plural(s, 'секунда', 'секунды', 'секунд')
  return table.concat(parts, ' ') .. ' назад'
end

-- ISO-8601 → epoch. Для разницы двух меток смещение часового пояса сокращается,
-- поэтому TZ тут не важен (используем только closed−created).
local function isoToEpoch(s)
  if type(s) ~= 'string' then return nil end
  local Y, Mo, D, H, Mi, S = s:match('(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)')
  if not Y then return nil end
  return os.time({ year = tonumber(Y), month = tonumber(Mo), day = tonumber(D),
                   hour = tonumber(H), min = tonumber(Mi), sec = tonumber(S) })
end

local VK_NAMES = {}
do
  for i = 1, 12 do VK_NAMES[0x70 + i - 1] = 'F'..i end
  for i = 0,  9 do VK_NAMES[0x30 + i] = tostring(i) end
  for i = 0, 25 do VK_NAMES[0x41 + i] = string.char(65 + i) end
  VK_NAMES[0x2D]='Insert'; VK_NAMES[0x2E]='Delete'
  VK_NAMES[0x24]='Home';   VK_NAMES[0x23]='End'
  VK_NAMES[0x21]='PgUp';   VK_NAMES[0x22]='PgDn'
  VK_NAMES[0xC0]='`';      VK_NAMES[0xBD]='-'; VK_NAMES[0xBB]='='
end

-- ─── Сочетания клавиш (модификаторы) ──────────────────────────
local hotkey_mods       = {}  -- набор активных модификаторов: { [0x11]=true }
local close_hotkey_mods = {}  -- модификаторы клавиши закрытия после успеха

local MOD_DEFS = {
  { vk = 0x11, name = 'Ctrl'  },  -- VK_CONTROL
  { vk = 0x10, name = 'Shift' },  -- VK_SHIFT
  { vk = 0x12, name = 'Alt'   },  -- VK_MENU
}

-- Зажатые сейчас модификаторы (для захвата и подсветки)
local function currentMods()
  local m = {}
  for _, d in ipairs(MOD_DEFS) do
    if isKeyDown(d.vk) then m[d.vk] = true end
  end
  return m
end

-- Названия модификаторов в фиксированном порядке
local function modNames(mods)
  local t = {}
  for _, d in ipairs(MOD_DEFS) do
    if mods[d.vk] then t[#t+1] = d.name end
  end
  return t
end

-- Полное сочетание как список названий: { 'Ctrl', 'F2' }
local function chordParts(vk, mods)
  local t = modNames(mods)
  t[#t+1] = VK_NAMES[vk] or ('0x'..string.format('%X', vk))
  return t
end
local function hotkeyParts()      return chordParts(hotkey_vk, hotkey_mods)             end
local function closeHotkeyParts() return chordParts(close_hotkey_vk, close_hotkey_mods) end

-- Срабатывание: точное совпадение модификаторов + нажатие основной клавиши
local function chordTriggered(vk, mods)
  if vk == 0 then return false end
  for _, d in ipairs(MOD_DEFS) do
    local need = mods[d.vk] and true or false
    local have = isKeyDown(d.vk) and true or false
    if need ~= have then return false end
  end
  return wasKeyPressed(vk)
end
local function hotkeyTriggered()      return chordTriggered(hotkey_vk, hotkey_mods)             end
local function closeHotkeyTriggered() return chordTriggered(close_hotkey_vk, close_hotkey_mods) end

-- ─── Общее положение окон ────────────────────────────────────
-- Все экраны делят общий центр win_cx/win_cy, чтобы при переходах окно не прыгало.
-- Позицию форсируем ТОЛЬКО в кадре смены экрана (один раз) — в остальные кадры окно
-- не трогаем, иначе ломается перетаскивание и окна с авто-высотой дрейфуют.
local win_cx, win_cy   = nil, nil
local pos_applied_for  = nil   -- для какого screen позиция уже выставлена

local function applyWindowPos()
  if not (win_cx and win_cy) then
    -- Первый показ за сессию — центрируем по экрану
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
  elseif pos_applied_for ~= screen then
    -- Сменили экран — один раз переносим новое окно в общий центр
    imgui.SetNextWindowPos(imgui.ImVec2(win_cx, win_cy), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    pos_applied_for = screen
  end
  -- В прочие кадры позицию не задаём: imgui сам держит окно и позволяет его таскать
end

-- Запомнить текущий центр окна (учитывает перетаскивание пользователем)
local function trackWindowPos()
  local p = imgui.GetWindowPos()
  local s = imgui.GetWindowSize()
  win_cx = p.x + s.x * 0.5
  win_cy = p.y + s.y * 0.5
end

-- Задать размер окна для экрана: ограничения min/max + стартовый размер.
-- Размер берём из сохранённого (win_sizes), иначе из дефолта. Cond.FirstUseEver:
-- imgui сам запоминает ручной ресайз пользователя, мы лишь задаём начальное значение.
local function applyWindowSize(scr, min_h)
  local def = WIN_DEF[scr] or { w = CFG.W, h = CFG.H }
  local mn  = WIN_MIN[scr] or { w = 360, h = 300 }
  local s   = win_sizes[scr]
  local w   = (s and s.w) or def.w
  local h   = (s and s.h) or def.h
  local sw, sh = getScreenResolution()
  -- min_h (опц.) — динамический минимум высоты (напр. чтобы при сужении контент
  -- не налезал на нижнюю строку аватар/«Выйти»). Не выходим за максимум 95% экрана.
  local min_height = math.min((min_h or mn.h), sh * 0.95)
  imgui.SetNextWindowSizeConstraints(
    imgui.ImVec2(mn.w, min_height),
    imgui.ImVec2(sw * 0.95, sh * 0.95))
  imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.FirstUseEver)
end

-- Запомнить текущий размер окна экрана (после ручного ресайза). Сохранение —
-- дебаунсом в main loop, чтобы не писать конфиг каждый кадр перетаскивания.
local function trackWindowSize(scr)
  local s   = imgui.GetWindowSize()
  local cur = win_sizes[scr]
  if not cur or math.abs(cur.w - s.x) > 0.5 or math.abs(cur.h - s.y) > 0.5 then
    win_sizes[scr] = { w = s.x, h = s.y }
    win_size_dirty = true
  end
end

-- Анимация масштаба логотипа при наведении
local logo_scale      = 1.0
local logo_scale_from = 1.0
local logo_scale_to   = 1.0
local logo_scale_t    = 0.0

-- Input буферы
local B = {
  nick  = imgui.new.char[65](''),
  token = imgui.new.char[7](''),
  brief = imgui.new.char[81](''),
  desc  = imgui.new.char[1025](''),
  loc   = imgui.new.char[129](''),
  tac   = imgui.new.char[33](''),
}

-- Ползунок громкости оповещений (0..100), синхронизируется с notify_vol
local vol_ref = imgui.new.int(70)

-- ═══════════════════════════════════════════════════════════
--  АНИМАЦИЯ ОКНА
-- ═══════════════════════════════════════════════════════════

local anim_alpha   = 0.0
local anim_from    = 0.0
local anim_to      = 0.0
local anim_start_t = 0.0
local is_closing   = false
local ANIM_DUR     = 0.18  -- секунды

local function smoothstep(x)
    x = math.max(0, math.min(1, x))
    return x * x * (3 - 2 * x)
end

local function updateAnim()
    local p = smoothstep((os.clock() - anim_start_t) / ANIM_DUR)
    anim_alpha = anim_from + (anim_to - anim_from) * p
end

local function startAnim(to)
    anim_from    = anim_alpha
    anim_to      = to
    anim_start_t = os.clock()
end

local function openWindow()
    is_closing = false
    visible[0] = true
    startAnim(1)
    -- После экрана успеха при следующем открытии возвращаемся к списку фракций,
    -- а не показываем снова «Вызов отправлен!».
    if screen == 'success' then
      screen = 'subdivisions'; sel_id = nil; cid = nil; success_at = nil
    end
    -- Добровольно открытый экран обновления не залипает (обязательное вернёт OnFrame)
    if screen == 'update' and not upd.required then
      screen = (auth and 'subdivisions') or 'token'
    end
    -- Полную карточку каллаута не показываем при повторном открытии — к списку
    if screen == 'callout_card' then screen = 'subdivisions' end
    -- Список подразделений перезапрашиваем не чаще SUBS_TTL: сбрасываем кэш,
    -- только если он устарел. Иначе показываем уже загруженный список мгновенно.
    if screen == 'subdivisions' and (os.clock() - subs_fetched_at) > SUBS_TTL then
      subs = {}
    end
    -- При открытии окна обновляем список активных каллаутов и до-тягиваем аватар,
    -- если он не загрузился ранее (например, бот был недоступен при старте)
    if auth then
      if fetchActiveCallouts then fetchActiveCallouts() end
      if fetchUserAvatar then fetchUserAvatar() end
    end
end

local function closeWindow()
    is_closing = true
    startAnim(0)
    success_at = nil  -- сбросить авто-таймер закрытия
end

-- ═══════════════════════════════════════════════════════════
--  ШРИФТЫ
-- ═══════════════════════════════════════════════════════════

local fnt_reg, fnt_bold, fnt_big, fnt_title, fnt_mono, fnt_ti_lg, fnt_ti_xl
local logo_tex = nil

imgui.OnInitialize(function()
  local io     = imgui.GetIO()
  local ranges = io.Fonts:GetGlyphRangesCyrillic()
  -- Минимальный диапазон для «иконочных» шрифтов (fnt_ti_lg/fnt_ti_xl):
  -- они рисуют только tabler-иконку (из merge) и максимум запасной '!',
  -- поэтому базовому Inter кириллица не нужна. Полный диапазон в 64px раздувал
  -- атлас и давал фриз при первом открытии окна.
  local ascii_only = imgui.new.ImWchar[3](0x20, 0x7E, 0)
  local cfg    = imgui.ImFontConfig()
  cfg.OversampleH, cfg.OversampleV = 2, 1
  local F = getWorkingDirectory() .. '/resource/fonts/'
  local W = os.getenv('WINDIR') .. '\\Fonts\\'

  -- Слияние FA6-иконок в шрифт. Вызывается сразу после AddFont.
  -- rawget используется везде, чтобы не触发 рекурсивный __index библиотеки.
  local function mergeIcons(sz)
    if not ok_fa then return end
    local ci = imgui.ImFontConfig()
    ci.MergeMode        = true
    ci.PixelSnapH       = true
    ci.GlyphMinAdvanceX = sz
    -- Безопасное чтение диапазона глифов (rawget не вызывает __index)
    local min_r = rawget(fa, 'min_range') or 0xE005
    local max_r = rawget(fa, 'max_range') or 0xF8FF
    local ir = imgui.new.ImWchar[3](min_r, max_r, 0)
    -- Сначала пробуем встроенный base85-шрифт
    local get_font = rawget(fa, 'get_font_data_base85')
    if get_font then
      pcall(function()
        io.Fonts:AddFontFromMemoryCompressedBase85TTF(get_font('solid'), sz, ci, ir)
      end)
      return
    end
    -- Fallback: отдельный TTF-файл (fa-solid-900.ttf рядом с другими шрифтами)
    local ttf = getWorkingDirectory() .. '/resource/fonts/fa-solid-900.ttf'
    if doesFileExist(ttf) then
      pcall(function() io.Fonts:AddFontFromFileTTF(ttf, sz, ci, ir) end)
    end
  end

  local function mergeTabler(sz)
    if not ok_ti then return end
    local ci2 = imgui.ImFontConfig()
    ci2.MergeMode = true; ci2.PixelSnapH = true; ci2.GlyphMinAdvanceX = sz
    local ir2 = imgui.new.ImWchar[3](ti.min_range, ti.max_range, 0)
    pcall(function()
      io.Fonts:AddFontFromMemoryCompressedBase85TTF(ti.get_font_data_base85(), sz, ci2, ir2)
    end)
  end

  fnt_reg   = io.Fonts:AddFontFromFileTTF(F..'Inter-Regular.ttf',  17, cfg, ranges)
  mergeIcons(14); mergeTabler(16)
  fnt_bold  = io.Fonts:AddFontFromFileTTF(F..'Inter-SemiBold.ttf', 17, cfg, ranges)
  mergeIcons(14); mergeTabler(16)
  fnt_big   = io.Fonts:AddFontFromFileTTF(F..'Inter-Bold.ttf',     23, cfg, ranges)
  mergeIcons(18); mergeTabler(18)
  fnt_ti_lg = io.Fonts:AddFontFromFileTTF(F..'Inter-Regular.ttf',  38, cfg, ascii_only)
  if ok_ti then
    local ci3 = imgui.ImFontConfig()
    ci3.MergeMode = true; ci3.PixelSnapH = true; ci3.GlyphMinAdvanceX = 38
    local ir3 = imgui.new.ImWchar[3](0xF640, 0xF680, 0)
    pcall(function()
      io.Fonts:AddFontFromMemoryCompressedBase85TTF(ti.get_font_data_base85(), 38, ci3, ir3)
    end)
  end
  fnt_title = io.Fonts:AddFontFromFileTTF(F..'Inter-Bold.ttf',     36, cfg, ranges)
  mergeIcons(28)
  fnt_ti_xl = io.Fonts:AddFontFromFileTTF(F..'Inter-Regular.ttf',  64, cfg, ascii_only)
  if ok_ti then
    local ci4 = imgui.ImFontConfig()
    ci4.MergeMode = true; ci4.PixelSnapH = true; ci4.GlyphMinAdvanceX = 64
    local ir4 = imgui.new.ImWchar[3](0xF640, 0xF720, 0)
    pcall(function()
      io.Fonts:AddFontFromMemoryCompressedBase85TTF(ti.get_font_data_base85(), 64, ci4, ir4)
    end)
  end
  fnt_mono  = io.Fonts:AddFontFromFileTTF(W..'consola.ttf',        22, nil, ranges)

  local logo_path = F .. 'saeslogo.png'
  local tex = imgui.CreateTextureFromFile(logo_path)
  if tex ~= nil then logo_tex = tex end

  io.ConfigWindowsMoveFromTitleBarOnly = false
end)

-- ═══════════════════════════════════════════════════════════
--  ТЕМА  (G-ES style: монохромный dark, белые акценты)
-- ═══════════════════════════════════════════════════════════

local FG     = imgui.ImVec4(0.92, 0.92, 0.92, 1.00)
local FG_DIM = imgui.ImVec4(0.40, 0.40, 0.42, 1.00)
local FG_10  = imgui.ImVec4(0.92, 0.92, 0.92, 0.10)
local FG_20  = imgui.ImVec4(0.92, 0.92, 0.92, 0.20)
local FG_30  = imgui.ImVec4(0.92, 0.92, 0.92, 0.30)
local FG_08  = imgui.ImVec4(0.92, 0.92, 0.92, 0.08)
local FG_12  = imgui.ImVec4(0.92, 0.92, 0.92, 0.12)
local FG_18  = imgui.ImVec4(0.92, 0.92, 0.92, 0.18)

local function applyTheme()
  local s = imgui.GetStyle()
  s.WindowRounding, s.FrameRounding, s.GrabRounding = 12, 6, 6
  s.ScrollbarRounding = 4
  s.WindowBorderSize, s.FrameBorderSize = 0, 0
  s.WindowPadding = imgui.ImVec2(20, 18)
  s.FramePadding  = imgui.ImVec2(12,  8)
  s.ItemSpacing   = imgui.ImVec2( 8,  8)
  s.ScrollbarSize = 3

  local c = s.Colors
  c[imgui.Col.WindowBg]             = imgui.ImVec4(0.04, 0.04, 0.04, 0.98)
  c[imgui.Col.ChildBg]              = imgui.ImVec4(0.06, 0.06, 0.06, 0.70)
  c[imgui.Col.PopupBg]              = imgui.ImVec4(0.05, 0.05, 0.05, 0.98)
  c[imgui.Col.Border]               = FG_20
  c[imgui.Col.BorderShadow]         = imgui.ImVec4(0, 0, 0, 0)
  c[imgui.Col.FrameBg]              = FG_08
  c[imgui.Col.FrameBgHovered]       = FG_12
  c[imgui.Col.FrameBgActive]        = FG_18
  c[imgui.Col.TitleBg]              = imgui.ImVec4(0.03, 0.03, 0.03, 1.00)
  c[imgui.Col.TitleBgActive]        = imgui.ImVec4(0.05, 0.05, 0.05, 1.00)
  c[imgui.Col.ScrollbarBg]          = imgui.ImVec4(0.02, 0.02, 0.02, 1.00)
  c[imgui.Col.ScrollbarGrab]        = imgui.ImVec4(0.30, 0.30, 0.30, 1.00)
  c[imgui.Col.ScrollbarGrabHovered] = imgui.ImVec4(0.50, 0.50, 0.50, 1.00)
  c[imgui.Col.ScrollbarGrabActive]  = FG
  c[imgui.Col.Button]               = FG_18
  c[imgui.Col.ButtonHovered]        = FG_30
  c[imgui.Col.ButtonActive]         = imgui.ImVec4(0.92, 0.92, 0.92, 0.45)
  c[imgui.Col.Header]               = FG_10
  c[imgui.Col.HeaderHovered]        = FG_12
  c[imgui.Col.HeaderActive]         = FG_20
  c[imgui.Col.Separator]            = FG_10
  c[imgui.Col.SeparatorHovered]     = FG_20
  c[imgui.Col.SeparatorActive]      = FG_30
  c[imgui.Col.Text]                 = FG
  c[imgui.Col.TextDisabled]         = FG_DIM
  c[imgui.Col.CheckMark]            = FG
  c[imgui.Col.SliderGrab]           = FG_30
  c[imgui.Col.SliderGrabActive]     = FG
  c[imgui.Col.NavHighlight]         = FG_30
end

-- ═══════════════════════════════════════════════════════════
--  ХЕЛПЕРЫ
-- ═══════════════════════════════════════════════════════════

local function str(buf)     return ffi.string(buf) end
local function setbuf(b, s) ffi.copy(b, tostring(s)) end

-- Иконка FA6 + пробел, или пустая строка.
-- Используем только __call (fa(name)), не fa[name] — чтобы не задеть
-- рекурсивный __index, который есть в некоторых версиях библиотеки.
local function ico(name)
    if not ok_fa then return '' end
    local glyph = rawget(fa, name:upper())
    if type(glyph) == 'string' and #glyph > 0 then return glyph .. ' ' end
    return ''
end

-- Иконка TablerIcons, или пустая строка.
local function tbi(name)
    if not ok_ti then return '' end
    local glyph
    pcall(function() glyph = ti[name] end)
    if type(glyph) == 'string' and #glyph > 0 then return glyph end
    return ''
end

-- ImU32 цвет из float RGBA
local function c32(r, g, b, a)
  local ri = math.min(255, math.floor(r * 255 + 0.5))
  local gi = math.min(255, math.floor(g * 255 + 0.5))
  local bi = math.min(255, math.floor(b * 255 + 0.5))
  local ai = math.min(255, math.floor(a * anim_alpha * 255 + 0.5))
  return ai * 16777216 + bi * 65536 + gi * 256 + ri
end

local function centerText(t)
  local w = imgui.GetContentRegionAvail().x
  imgui.SetCursorPosX(imgui.GetCursorPosX() + (w - imgui.CalcTextSize(t).x) * 0.5)
  imgui.Text(t)
end

local function shadowText(t, alpha)
  local x = imgui.GetCursorPosX()
  local y = imgui.GetCursorPosY()
  imgui.SetCursorPos(imgui.ImVec2(x + 1, y + 2))
  imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 0, 0, alpha or 0.55))
  imgui.Text(t)
  imgui.PopStyleColor()
  imgui.SetCursorPos(imgui.ImVec2(x, y))
  imgui.Text(t)
end

local function shadowCenterText(t, alpha)
  local w  = imgui.GetContentRegionAvail().x
  local tw = imgui.CalcTextSize(t).x
  local x  = imgui.GetCursorPosX() + (w - tw) * 0.5
  local y  = imgui.GetCursorPosY()
  imgui.SetCursorPos(imgui.ImVec2(x + 1, y + 2))
  imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0, 0, 0, alpha or 0.55))
  imgui.Text(t)
  imgui.PopStyleColor()
  imgui.SetCursorPos(imgui.ImVec2(x, y))
  imgui.Text(t)
end


local function drawDecor()
  local dl  = imgui.GetWindowDrawList()
  local wp  = imgui.GetWindowPos()
  local ws  = imgui.GetWindowSize()
  local rad = 12  -- совпадает с WindowRounding

end

local function accentText(t)
  imgui.Text(t)
end

local function drawCloseBtn()
  local wp  = imgui.GetWindowPos()
  local ws  = imgui.GetWindowSize()
  local dl  = imgui.GetWindowDrawList()
  local sz, pad = 22, 12
  local x1 = wp.x + ws.x - sz - pad
  local y1 = wp.y + pad
  local x2, y2 = x1 + sz, y1 + sz

  local hov = imgui.IsMouseHoveringRect(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2), false)

  if hov then
    dl:AddRectFilled(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2), c32(1, 1, 1, 0.08), 5, 15)
  end

  local col  = hov and c32(0.95, 0.95, 0.95, 1) or c32(0.40, 0.40, 0.42, 1)
  local icon = ok_ti and ti('x') or 'x'
  local iw   = imgui.CalcTextSize(icon).x
  local ih   = imgui.GetFontSize()
  dl:AddText(
    imgui.ImVec2((x1+x2)*0.5 - iw*0.5, (y1+y2)*0.5 - ih*0.5),
    col, icon)

  if hov and imgui.IsMouseClicked(0) then closeWindow() end
end

local function drawSettingsBtn()
  local wp  = imgui.GetWindowPos()
  local ws  = imgui.GetWindowSize()
  local dl  = imgui.GetWindowDrawList()
  local sz, pad = 22, 12
  local x1 = wp.x + ws.x - sz - pad - sz - 4
  local y1 = wp.y + pad
  local x2, y2 = x1 + sz, y1 + sz

  local hov = imgui.IsMouseHoveringRect(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2), false)
  if hov then
    dl:AddRectFilled(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2), c32(1, 1, 1, 0.08), 5, 15)
  end

  local col  = hov and c32(0.95, 0.95, 0.95, 1) or c32(0.40, 0.40, 0.42, 1)
  local icon = ok_ti and ti('settings') or '?'
  local iw   = imgui.CalcTextSize(icon).x
  local ih   = imgui.GetFontSize()
  dl:AddText(
    imgui.ImVec2((x1+x2)*0.5 - iw*0.5, (y1+y2)*0.5 - ih*0.5),
    col, icon)

  if hov and imgui.IsMouseClicked(0) then
    prev_screen = screen; screen = 'settings'; waiting_key = false
    success_at = nil  -- уход с экрана успеха в настройки сбрасывает авто-таймер
  end
end

local function mutedText(t)
  imgui.PushStyleColor(imgui.Col.Text, FG_DIM)
  imgui.Text(t)
  imgui.PopStyleColor()
end

local function errorText(t)
  imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.95, 0.35, 0.35, 1))
  imgui.TextWrapped(t)
  imgui.PopStyleColor()
end

-- Убирает лидирующие emoji/спецсимволы, оставляет ASCII и кириллицу
local function cleanMsg(s)
  local i = 1
  while i <= #s do
    local b = string.byte(s, i)
    if (b >= 32 and b <= 126) or b == 208 or b == 209 then return s:sub(i) end
    i = i + 1
  end
  return s
end

local function fieldLabel(t)
  imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.45, 0.45, 0.48, 1))
  imgui.Text(t)
  imgui.PopStyleColor()
end

local _btn_lift  = {}
local _card_lift = {}

local function fullBtn(label, disabled, id)
  id = id or label  -- ключ для lift-анимации и imgui-id (текст кнопки = label)
  local avail = imgui.GetContentRegionAvail().x
  local h     = 40
  local cp    = imgui.GetCursorPos()
  local wp    = imgui.GetWindowPos()
  local dl    = imgui.GetWindowDrawList()
  local x1    = wp.x + cp.x
  local y1    = wp.y + cp.y
  local x2    = x1 + avail
  local y2    = y1 + h
  local rad   = 6

  if disabled then
    imgui.Dummy(imgui.ImVec2(avail, h))
    dl:AddRect(imgui.ImVec2(x1,y1), imgui.ImVec2(x2,y2), c32(0.92,0.92,0.92,0.06), rad, 15, 1)
    local tw = imgui.CalcTextSize(label).x
    local fh = imgui.GetFontSize()
    dl:AddText(imgui.ImVec2(x1+(avail-tw)*0.5, y1+(h-fh)*0.5), c32(0.92,0.92,0.92,0.14), label)
    return false
  end

  local clicked = imgui.InvisibleButton('##fb_'..id, imgui.ImVec2(avail, h))
  local hov = imgui.IsItemHovered()
  local act = imgui.IsItemActive()

  -- Плавный подъём кнопки при hover
  _btn_lift[id] = (_btn_lift[id] or 0)
  local target = (hov and not act) and 1 or 0
  _btn_lift[id] = _btn_lift[id] + (target - _btn_lift[id]) * 0.16
  local lift = _btn_lift[id] * 3  -- максимум 3px вверх

  local ry1 = y1 - lift
  local ry2 = y2 - lift

  -- Тень снизу (усиливается с подъёмом — создаёт ощущение высоты)
  if _btn_lift[id] > 0.01 then
    local sh = _btn_lift[id]
    dl:AddRectFilled(
      imgui.ImVec2(x1 + 6, ry2 + 2),
      imgui.ImVec2(x2 - 6, ry2 + 8 + lift),
      c32(0, 0, 0, 0.21 * sh), 4, 15)
  end

  -- Фон кнопки
  local fill = act and 0.78 or (hov and 0.95 or 0.92)
  dl:AddRectFilled(imgui.ImVec2(x1,ry1), imgui.ImVec2(x2,ry2), c32(fill,fill,fill,1.0), rad, 15)


  -- Текст тёмный поверх белой кнопки
  local tw = imgui.CalcTextSize(label).x
  local fh = imgui.GetFontSize()
  dl:AddText(
    imgui.ImVec2(x1+(avail-tw)*0.5, ry1+(h-fh)*0.5),
    c32(0.06,0.06,0.06,1.0), label)

  return clicked
end

-- ─── Сетка-фон ────────────────────────────────────────────────
local GRID_SZ = 24

local function drawGrid()
  local dl  = imgui.GetWindowDrawList()
  local wp  = imgui.GetWindowPos()
  local ws  = imgui.GetWindowSize()
  local col = c32(1, 1, 1, 0.009)
  local r   = 12  -- совпадает с WindowRounding
  -- Обрезаем сетку по скруглённым краям окна
  dl:PushClipRect(
    imgui.ImVec2(wp.x + r, wp.y + r),
    imgui.ImVec2(wp.x + ws.x - r, wp.y + ws.y - r), true)
  local x = wp.x
  while x <= wp.x + ws.x do
    dl:AddLine(imgui.ImVec2(x, wp.y), imgui.ImVec2(x, wp.y + ws.y), col)
    x = x + GRID_SZ
  end
  local y = wp.y
  while y <= wp.y + ws.y do
    dl:AddLine(imgui.ImVec2(wp.x, y), imgui.ImVec2(wp.x + ws.x, y), col)
    y = y + GRID_SZ
  end
  dl:PopClipRect()
end

-- ─── Placeholder для InputText ─────────────────────────────────
local function drawPlaceholder(is_empty, hint)
  if is_empty and not imgui.IsItemActive() then
    local rmin = imgui.GetItemRectMin()
    local fp   = imgui.GetStyle().FramePadding
    imgui.GetWindowDrawList():AddText(
      imgui.ImVec2(rmin.x + fp.x, rmin.y + fp.y),
      c32(0.34, 0.34, 0.37, 1), hint)
  end
end

-- ─── Декоративный разделитель с подписью ──────────────────────
local function sectionLabel(label)
  local dl    = imgui.GetWindowDrawList()
  local wp    = imgui.GetWindowPos()
  local cp    = imgui.GetCursorPos()
  local avail = imgui.GetContentRegionAvail().x
  local tw    = imgui.CalcTextSize(label).x
  local gap   = 10
  local cy    = wp.y + cp.y + 7
  local cx    = wp.x + cp.x
  local mid   = cx + avail * 0.5
  dl:AddLine(imgui.ImVec2(cx, cy), imgui.ImVec2(mid - tw*0.5 - gap, cy), c32(0.92, 0.92, 0.92, 0.10))
  dl:AddLine(imgui.ImVec2(mid + tw*0.5 + gap, cy), imgui.ImVec2(cx + avail, cy), c32(0.92, 0.92, 0.92, 0.10))
  dl:AddText(imgui.ImVec2(mid - tw*0.5, cy - 7), c32(0.92, 0.92, 0.92, 0.26), label)
  imgui.Dummy(imgui.ImVec2(avail, 14))
end

-- ─── Сочетание клавиш в виде «капсул» ─────────────────────────
-- parts — список строк ({'Ctrl','F2'}), рисуется по центру области
local function drawHotkeyChord(dl, kx1, ky1, avail, kh, parts, alpha)
  local fh    = imgui.GetFontSize()
  local padx  = 9
  local pillh = fh + 12
  local sepw  = imgui.CalcTextSize('+').x
  local sgap  = 7   -- зазор между капсулой и «+»
  -- общая ширина
  local widths = {}
  local total  = 0
  for i, s in ipairs(parts) do
    local w = imgui.CalcTextSize(s).x + padx*2
    widths[i] = w
    total = total + w
    if i < #parts then total = total + sgap*2 + sepw end
  end
  local x  = kx1 + (avail - total) * 0.5
  local py = ky1 + (kh - pillh) * 0.5
  for i, s in ipairs(parts) do
    local w = widths[i]
    dl:AddRectFilled(imgui.ImVec2(x, py), imgui.ImVec2(x+w, py+pillh), c32(0.92,0.92,0.92, 0.10*alpha), 5, 15)
    dl:AddRect(imgui.ImVec2(x, py), imgui.ImVec2(x+w, py+pillh), c32(0.92,0.92,0.92, 0.22*alpha), 5, 15, 1)
    local tw = imgui.CalcTextSize(s).x
    dl:AddText(imgui.ImVec2(x + (w-tw)*0.5, py + (pillh-fh)*0.5), c32(0.92,0.92,0.92, 0.88*alpha), s)
    x = x + w
    if i < #parts then
      x = x + sgap
      dl:AddText(imgui.ImVec2(x, ky1 + (kh-fh)*0.5), c32(0.92,0.92,0.92, 0.40*alpha), '+')
      x = x + sepw + sgap
    end
  end
end

-- ─── Пошаговая инструкция ─────────────────────────────────────
local function drawInstructions()
  local steps = {
    { n = '01', t = 'Зайди на Discord-сервер SAES' },
    { n = '02', t = 'Введи команду  /samp link  в боте' },
    { n = '03', t = 'Скопируй и введи 6-значный токен' },
  }
  local dl  = imgui.GetWindowDrawList()
  local wp  = imgui.GetWindowPos()
  local avail = imgui.GetContentRegionAvail().x

  -- Подложка
  local cp0 = imgui.GetCursorPos()
  dl:AddRectFilled(
    imgui.ImVec2(wp.x + cp0.x - 2, wp.y + cp0.y - 6),
    imgui.ImVec2(wp.x + cp0.x + avail + 2, wp.y + cp0.y + 88),
    c32(0.06, 0.06, 0.09, 0.60), 6, 15)

  imgui.Spacing()
  for i, s in ipairs(steps) do
    local cp   = imgui.GetCursorPos()
    local dot_x = wp.x + cp.x + 14
    local dot_y = wp.y + cp.y + 9

    -- Вертикальный коннектор к следующему шагу
    if i < #steps then
      dl:AddLine(
        imgui.ImVec2(dot_x, dot_y + 5),
        imgui.ImVec2(dot_x, dot_y + 26),
        c32(0.92, 0.92, 0.92, 0.06), 1)
    end

    -- Кружок шага
    dl:AddCircle(imgui.ImVec2(dot_x, dot_y), 5, c32(0.92, 0.92, 0.92, 0.18), 12, 1)

    -- Номер шага
    imgui.SetCursorPosX(cp.x + 4)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.22, 0.22, 0.24, 1))
    imgui.Text(s.n)
    imgui.PopStyleColor()

    imgui.SameLine(0, 14)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.44, 0.44, 0.47, 1))
    imgui.Text(s.t)
    imgui.PopStyleColor()

    if i < #steps then imgui.Spacing() end
  end
  imgui.Spacing()
end

-- ─── Прогресс токена: кружки, соединённые линией ──────────────
local function tokenDots(tok)
  local dl    = imgui.GetWindowDrawList()
  local wp    = imgui.GetWindowPos()
  local cp    = imgui.GetCursorPos()
  local avail = imgui.GetContentRegionAvail().x
  local n     = 6
  local r     = 4.5
  local spc   = 22
  local total = (n - 1) * spc + r * 2
  local sx    = wp.x + cp.x + (avail - total) * 0.5 + r
  local sy    = wp.y + cp.y + 10
  dl:AddLine(imgui.ImVec2(sx, sy), imgui.ImVec2(sx + (n-1)*spc, sy), c32(0.92, 0.92, 0.92, 0.07), 1.5)
  for i = 1, n do
    local cx = sx + (i - 1) * spc
    if i <= #tok then
      dl:AddCircleFilled(imgui.ImVec2(cx, sy), r, c32(0.92, 0.92, 0.92, 0.88), 16)
    else
      dl:AddCircle(imgui.ImVec2(cx, sy), r, c32(0.92, 0.92, 0.92, 0.13), 16, 1)
    end
  end
  imgui.Dummy(imgui.ImVec2(avail, 20))
end

-- Анимированный лоадер: три пульсирующих точки на одной строке с текстом
local function loaderDots(label)
    local t = os.clock()
    imgui.PushStyleColor(imgui.Col.Text, FG_DIM)
    imgui.Text('  ' .. label)
    imgui.PopStyleColor()
    imgui.SameLine(0, 8)
    for i = 1, 3 do
        local v = (math.sin(t * 5 - (i - 1) * 0.8) + 1) * 0.5
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.92, 0.92, 0.92, 0.20 + v * 0.80))
        imgui.Text('.')
        imgui.PopStyleColor()
        if i < 3 then imgui.SameLine(0, 4) end
    end
end

-- ═══════════════════════════════════════════════════════════
--  HTTP
-- ═══════════════════════════════════════════════════════════

local function api(method, path, body, token, cb)
  local raw  = body and json.encode(body) or nil
  local hdrs = { ['Content-Type'] = 'application/json', ['Connection'] = 'close' }
  if raw   then hdrs['Content-Length'] = tostring(#raw) end
  if token then hdrs['Authorization']  = 'Bearer ' .. token end
  hdrs['X-Script-Version'] = VERSION  -- сервер пишет версию пользователя для /samp versions
  http_queue[#http_queue + 1] = {
    method = method,
    url    = CFG.bot_url .. path,
    hdrs   = hdrs,
    body   = raw,
    cb     = cb,
  }
end

-- ═══════════════════════════════════════════════════════════
--  СОХРАНЕНИЕ
-- ═══════════════════════════════════════════════════════════

-- Сериализация набора модификаторов в строку VK-кодов через запятую
local function modsToStr(mods)
  local s = ''
  for _, d in ipairs(MOD_DEFS) do
    if mods[d.vk] then s = s .. (s ~= '' and ',' or '') .. d.vk end
  end
  return s
end
local function strToMods(str)
  local t = {}
  if str then for code in str:gmatch('%d+') do t[tonumber(code)] = true end end
  return t
end

local function saveConfig()
  if ok_lfs then lfs.mkdir(getWorkingDirectory() .. '/config') end
  local f = io.open(CFG.cfg_file, 'w')
  if f then
    -- Строки: auth, nick, hotkey_vk, hotkey_mods, close_hotkey_vk, close_hotkey_mods,
    --         window_sizes (JSON). auth/nick могут быть пустыми (не авторизован).
    pcall(function()
      win_sizes._v = LAYOUT_VER  -- метка схемы для миграции дефолтов
      local sizes_json = json.encode(win_sizes) or '{}'
      f:write((auth or '')..'\n'..(nick or '')..'\n'
        ..tostring(hotkey_vk)..'\n'..modsToStr(hotkey_mods)..'\n'
        ..tostring(close_hotkey_vk)..'\n'..modsToStr(close_hotkey_mods)..'\n'
        ..sizes_json..'\n'
        ..tostring(math.floor(notify_vol * 100 + 0.5)))  -- громкость 0..100
    end)
    f:close()
  end
end

local function loadConfig()
  local f = io.open(CFG.cfg_file, 'r')
  if not f then return end
  local a, n, k, m, ck, cm, sz, vol
  pcall(function()
    a = f:read('*l'); n = f:read('*l'); k = f:read('*l'); m = f:read('*l')
    ck = f:read('*l'); cm = f:read('*l')  -- nil в старых конфигах (4 строки) — это норм
    sz = f:read('*l')                     -- JSON размеров окон (нет в старых конфигах)
    vol = f:read('*l')                    -- громкость 0..100 (нет в старых конфигах)
  end)
  f:close()
  if a and n and #a > 10 and #n > 1 then
    auth = a; nick = n; screen = 'subdivisions'
  end
  hotkey_vk         = tonumber(k)  or 0
  hotkey_mods       = strToMods(m)
  close_hotkey_vk   = tonumber(ck) or 0
  close_hotkey_mods = strToMods(cm)
  if sz and #sz > 1 then
    local ok_d, t = pcall(json.decode, sz)
    -- Применяем сохранённые размеры только если схема совпадает; иначе сброс к дефолтам
    if ok_d and type(t) == 'table' and t._v == LAYOUT_VER then win_sizes = t end
  end
  local v = tonumber(vol)
  if v then
    notify_vol = math.max(0, math.min(1, v / 100))
    vol_ref[0] = math.floor(notify_vol * 100 + 0.5)
  end
end

-- ═══════════════════════════════════════════════════════════
--  ОБНОВЛЕНИЕ
-- ═══════════════════════════════════════════════════════════

-- Сравнение semver: -1 если a<b, 0 если равны, 1 если a>b
local function cmpVer(a, b)
  local function parts(s)
    local t = {}
    for n in tostring(s or ''):gmatch('%d+') do t[#t + 1] = tonumber(n) end
    return t
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

-- Применить распарсенный version.json: выставить состояние и оповестить в чат
local function applyVersionInfo(data)
  if type(data) ~= 'table' or type(data.latest) ~= 'string' then return end
  upd.latest    = data.latest
  upd.changelog = type(data.changelog) == 'string' and data.changelog or nil
  upd.dl_url    = type(data.url) == 'string' and data.url or nil
  upd.available = cmpVer(VERSION, data.latest) < 0
  upd.required  = type(data.min_supported) == 'string' and cmpVer(VERSION, data.min_supported) < 0

  if upd.required then
    screen = 'update'
    sampAddChatMessage(u8:decode('{DC143C}[SAES CALLOUT]{FFFFFF} Ваша версия '..VERSION..' устарела и больше не поддерживается. Обновитесь: {DC143C}/callout update{FFFFFF} или вручную: '..CFG.repo_url), -1)
  elseif upd.available then
    sampAddChatMessage(u8:decode('{DC143C}[SAES CALLOUT]{FFFFFF} Доступна новая версия {DC143C}'..data.latest..'{FFFFFF} (у вас '..VERSION..'). Команда {DC143C}/callout update{FFFFFF} — автообновление, или вручную: '..CFG.repo_url), -1)
    if upd.changelog then
      sampAddChatMessage(u8:decode('{888888}Что нового: '..upd.changelog), -1)
    end
  end
end

-- Проверить версию: качаем version.json и опрашиваем файл (без блокировки игры)
local function checkForUpdate()
  if ok_lfs then lfs.mkdir(getWorkingDirectory() .. '/config') end
  local tmp = getWorkingDirectory() .. '/config/saes_callout_version.json'
  os.remove(tmp)
  downloadUrlToFile(CFG.version_url, tmp)
  lua_thread.create(function()
    local deadline = os.clock() + 10
    while os.clock() < deadline do
      wait(300)
      local f = io.open(tmp, 'r')
      if f then
        local raw = f:read('*a'); f:close()
        if raw and #raw > 0 then
          local data = json.decode(raw)
          if type(data) == 'table' and type(data.latest) == 'string' then
            applyVersionInfo(data)
            return
          end
        end
      end
    end
  end)
end

-- Размер локального файла в байтах (nil, если файла нет)
local function localFileSize(path)
  if ok_lfs then return lfs.attributes(path, 'size') end
  local f = io.open(path, 'rb'); if not f then return nil end
  local s = f:seek('end'); f:close(); return s
end

-- Создать все промежуточные папки для файла (по компонентам пути)
local function ensureDirs(fullpath)
  if not ok_lfs then return end
  local dir = fullpath:match('^(.*)[/\\][^/\\]+$')
  if not dir then return end
  local acc
  for part in dir:gmatch('[^/\\]+') do
    acc = acc and (acc .. '/' .. part) or part
    lfs.mkdir(acc)
  end
end

-- Синхронизация папки resource/ с GitHub по манифесту: качаем только
-- отсутствующие или изменённые (по размеру) файлы. cb(ok) — по завершении.
local function syncResources(cb)
  local wd    = getWorkingDirectory()
  local mtmp  = wd .. '/config/saes_callout_manifest.json'
  if ok_lfs then lfs.mkdir(wd .. '/config') end
  os.remove(mtmp)
  downloadUrlToFile(CFG.raw_base .. 'resource/manifest.json', mtmp)

  lua_thread.create(function()
    -- Ждём манифест (до 10 c)
    local manifest
    local deadline = os.clock() + 10
    while os.clock() < deadline do
      wait(300)
      local f = io.open(mtmp, 'r')
      if f then
        local raw = f:read('*a'); f:close()
        if raw and #raw > 0 then
          local d = json.decode(raw)
          if type(d) == 'table' and type(d.files) == 'table' then manifest = d; break end
        end
      end
    end
    if not manifest then if cb then cb(false) end; return end

    -- Что качать: нет локально или размер не совпал
    local todo = {}
    for _, it in ipairs(manifest.files) do
      if type(it.path) == 'string' then
        local sz = localFileSize(wd .. '/' .. it.path)
        if not (sz and tonumber(it.size) and sz == tonumber(it.size)) then
          todo[#todo + 1] = it
        end
      end
    end
    if #todo == 0 then if cb then cb(true) end; return end
    upd.status = ('Ресурсы: 0/%d...'):format(#todo)

    -- Качаем по одному, ждём появления нужного размера (до 20 c на файл)
    for i, it in ipairs(todo) do
      local lp = wd .. '/' .. it.path
      ensureDirs(lp)
      os.remove(lp)
      downloadUrlToFile(CFG.raw_base .. it.path, lp)
      local dl = os.clock() + 20
      while os.clock() < dl do
        wait(250)
        local s = localFileSize(lp)
        if s and tonumber(it.size) and s >= tonumber(it.size) then break end
      end
      upd.status = ('Ресурсы: %d/%d...'):format(i, #todo)
    end
    if cb then cb(true) end
  end)
end

-- Автообновление: качаем новый .lua, проверяем, перезаписываем себя и перезагружаемся
local function doAutoUpdate()
  if upd.busy then return end
  if not upd.dl_url then
    sampAddChatMessage(u8:decode('{DC143C}[SAES CALLOUT]{FFFFFF} Ссылка на обновление недоступна. Скачайте вручную: '..CFG.repo_url), -1)
    return
  end
  if not (upd.available or upd.required) then
    sampAddChatMessage(u8:decode('{DC143C}[SAES CALLOUT]{FFFFFF} У вас уже последняя версия ('..VERSION..').'), -1)
    return
  end
  upd.busy = true
  upd.status = 'Синхронизация ресурсов...'
  local path    = thisScript().path
  local staging = path .. '.new'

  -- Сначала докачиваем недостающие/изменённые ресурсы, затем сам .lua и reload
  syncResources(function()
  upd.status = 'Загрузка обновления...'
  os.remove(staging)
  downloadUrlToFile(upd.dl_url, staging)

  lua_thread.create(function()
    local deadline = os.clock() + 30
    local last_size = -1
    while os.clock() < deadline do
      wait(400)
      local f = io.open(staging, 'rb')
      if f then
        local data = f:read('*a'); f:close()
        local size = data and #data or 0
        -- Валидно: непустой, похож на наш скрипт, и размер стабилен между проверками
        if size > 1000 and data:find('SAES Callout System', 1, true) then
          if size == last_size then
            local out = io.open(path, 'wb')
            if out then
              out:write(data); out:close()
              os.remove(staging)
              upd.status = 'Установлено, перезагрузка...'
              sampAddChatMessage(u8:decode('{DC143C}[SAES CALLOUT]{FFFFFF} Обновление установлено, перезагружаю скрипт...'), -1)
              -- Сообщить серверу об автообновлении (для audit log) ДО перезагрузки.
              -- Ждём ответа до 3с, иначе reload оборвал бы запрос.
              if auth then
                local reported = false
                api('POST', '/api/samp/update-applied',
                  { from = VERSION, to = (upd.latest or '') }, auth,
                  function() reported = true end)
                local rdl = os.clock() + 3
                while not reported and os.clock() < rdl do wait(50) end
              end
              wait(200)
              thisScript():reload()
              return
            end
          end
          last_size = size
        end
      end
    end
    upd.busy = false
    upd.status = nil
    os.remove(staging)
    sampAddChatMessage(u8:decode('{DC143C}[SAES CALLOUT]{FFFFFF} Не удалось автообновиться. Скачайте вручную: '..CFG.repo_url), -1)
  end)
  end)
end

-- ═══════════════════════════════════════════════════════════
--  ФУТЕР С ГИПЕРССЫЛКОЙ НА DISCORD
-- ═══════════════════════════════════════════════════════════

local discord_hovered = false

local function drawDiscordFooter()
  local disc_g = tbi('ICON_BRAND_DISCORD_FILLED')
  local label  = 'Дискорд первого экстренного'
  local full   = (disc_g ~= '' and (disc_g .. '  ') or '') .. label

  local avail = imgui.GetContentRegionAvail().x
  local tw    = imgui.CalcTextSize(full).x
  imgui.SetCursorPosX(imgui.GetCursorPosX() + (avail - tw) * 0.5)

  local col = discord_hovered
    and imgui.ImVec4(0.60, 0.70, 1.00, 1.00)
    or  imgui.ImVec4(0.45, 0.55, 0.90, 0.70)

  imgui.PushStyleColor(imgui.Col.Text, col)
  imgui.Text(full)
  imgui.PopStyleColor()

  discord_hovered = imgui.IsItemHovered()
  if discord_hovered then
    local dl = imgui.GetWindowDrawList()
    local mn = imgui.GetItemRectMin()
    local mx = imgui.GetItemRectMax()
    dl:AddLine(
      imgui.ImVec2(mn.x, mx.y - 1),
      imgui.ImVec2(mx.x, mx.y - 1),
      c32(0.55, 0.65, 1.0, 0.55), 1)
    if imgui.IsMouseClicked(0) then
      os.execute('start "" "' .. CFG.discord_url .. '"')
    end
  end
end

-- ═══════════════════════════════════════════════════════════
--  ЭКРАН: ТОКЕН
-- ═══════════════════════════════════════════════════════════

local function drawToken()
  local sw, sh = getScreenResolution()
  applyWindowPos()
  applyWindowSize('token')
  local flags = imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
  if not imgui.Begin('##token', visible, flags) then imgui.End(); return end
  trackWindowPos(); trackWindowSize('token')
  drawGrid()
  drawDecor()
  drawCloseBtn()
  drawSettingsBtn()

  imgui.Spacing()

  -- Логотип
  if logo_tex then
    local logo_h = 80
    local logo_w = logo_h * (256 / 174)
    local avail  = imgui.GetContentRegionAvail().x
    local lx     = imgui.GetCursorPosX() + (avail - logo_w) * 0.5
    local ly     = imgui.GetCursorPosY()
    local wpos   = imgui.GetWindowPos()
    local cx = wpos.x + lx + logo_w * 0.5
    local cy = wpos.y + ly + logo_h * 0.5
    local dl = imgui.GetWindowDrawList()

    local hov = imgui.IsMouseHoveringRect(
      imgui.ImVec2(cx - logo_w * 0.5, cy - logo_h * 0.5),
      imgui.ImVec2(cx + logo_w * 0.5, cy + logo_h * 0.5), false)
    local tgt = hov and 1.07 or 1.0
    if tgt ~= logo_scale_to then
      logo_scale_from = logo_scale
      logo_scale_to   = tgt
      logo_scale_t    = os.clock()
    end
    logo_scale = logo_scale_from
      + (logo_scale_to - logo_scale_from)
      * smoothstep(math.min(1, (os.clock() - logo_scale_t) / 0.15))

    local center = imgui.ImVec2(cx, cy)
    for i = 22, 1, -1 do
      local r = 38 + (130 - 38) * i / 22
      local t = 1.0 - i / 22
      dl:AddCircleFilled(center, r, c32(1, 1, 1, 0.0035 * t * t), 48)
    end

    local lw = logo_w * logo_scale
    local lh = logo_h * logo_scale
    dl:AddImage(logo_tex,
      imgui.ImVec2(cx - lw * 0.5, cy - lh * 0.5),
      imgui.ImVec2(cx + lw * 0.5, cy + lh * 0.5),
      imgui.ImVec2(0, 0), imgui.ImVec2(1, 1), c32(1, 1, 1, 1))

    imgui.SetCursorPosX(lx)
    imgui.SetCursorPosY(ly)
    imgui.Dummy(imgui.ImVec2(logo_w, logo_h))
  end

  imgui.Spacing()
  imgui.PushFont(fnt_big)
  imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.88, 0.88, 0.90, 0.72))
  shadowCenterText('Система экстренного вызова', 0.35)
  imgui.PopStyleColor()
  imgui.PopFont()
  imgui.Spacing()

  if not show_auth then
    imgui.Spacing()
    if fullBtn('Авторизация', false) then
      show_auth = true; err_msg = nil
    end
    imgui.Spacing()
  else
    -- Приветствие с ником в стиле sectionLabel
    imgui.PushFont(fnt_bold)
    do
      local dl    = imgui.GetWindowDrawList()
      local wp    = imgui.GetWindowPos()
      local cp    = imgui.GetCursorPos()
      local avail = imgui.GetContentRegionAvail().x
      local txt   = 'Привет, ' .. (local_nick or '...') .. '.'
      local tw    = imgui.CalcTextSize(txt).x
      local fh    = imgui.GetFontSize()
      local gap   = 12
      local cy    = wp.y + cp.y + fh * 0.5
      local cx    = wp.x + cp.x
      local mid   = cx + avail * 0.5
      dl:AddLine(imgui.ImVec2(cx, cy),                       imgui.ImVec2(mid - tw*0.5 - gap, cy), c32(0.92,0.92,0.92,0.25))
      dl:AddLine(imgui.ImVec2(mid + tw*0.5 + gap, cy),      imgui.ImVec2(cx + avail, cy),          c32(0.92,0.92,0.92,0.25))
      dl:AddText( imgui.ImVec2(mid - tw*0.5, wp.y + cp.y),  c32(0.92,0.92,0.92,0.55), txt)
      imgui.Dummy(imgui.ImVec2(avail, fh + 2))
    end
    imgui.PopFont()
    imgui.Spacing()
    imgui.Spacing()
    imgui.Spacing()

    -- Токен — 6 кастомных ячеек по центру
    local cell_count = 6
    local cell_w     = 32
    local cell_gap   = 10
    local total_w    = cell_count * cell_w + (cell_count - 1) * cell_gap
    local avail_tok  = imgui.GetContentRegionAvail().x
    imgui.SetCursorPosX(imgui.GetCursorPosX() + (avail_tok - total_w) * 0.5)

    imgui.PushFont(fnt_title)

    -- Прозрачный InputText для захвата ввода (невидим, поверх — ячейки)
    imgui.PushStyleColor(imgui.Col.FrameBg,        imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive,  imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.Text,           imgui.ImVec4(0,0,0,0))
    imgui.PushItemWidth(total_w)
    local changed   = imgui.InputText('##tok', B.token, 7, imgui.InputTextFlags.CharsDecimal)
    local is_active = imgui.IsItemActive()
    local mn        = imgui.GetItemRectMin()
    local mx        = imgui.GetItemRectMax()
    imgui.PopItemWidth()
    imgui.PopStyleColor(4)

    -- Рисуем ячейки поверх InputText
    local dl      = imgui.GetWindowDrawList()
    local fh      = imgui.GetFontSize()
    local ih      = mx.y - mn.y
    local tok_str = str(B.token)

    -- Фоновый прямоугольник с закруглёнными углами
    local pad_x, pad_y = 10, 6
    local rx1 = mn.x - pad_x
    local ry1 = mn.y - pad_y
    local rx2 = mx.x + pad_x
    local ry2 = mx.y + pad_y
    local rrad = 6
    dl:AddRectFilled(imgui.ImVec2(rx1,ry1), imgui.ImVec2(rx2,ry2), c32(0.08,0.08,0.08,0.30), rrad, 15)
    dl:AddRect(     imgui.ImVec2(rx1,ry1), imgui.ImVec2(rx2,ry2),
      is_active and c32(0.92,0.92,0.92,0.07) or c32(0.92,0.92,0.92,0.03), rrad, 15, 1.0)

    -- Placeholder
    if tok_str == '' and not is_active then
      local ph     = 'Введите токен'
      local ph_w   = imgui.CalcTextSize(ph).x
      local ph_h   = imgui.GetFontSize()
      dl:AddText(
        imgui.ImVec2((rx1+rx2)*0.5 - ph_w*0.5, (ry1+ry2)*0.5 - ph_h*0.5),
        c32(0.92,0.92,0.92,0.22), ph)
    end

    for i = 1, cell_count do
      local char     = tok_str:sub(i, i)
      local has_char = char ~= ''
      local bx       = mn.x + (i - 1) * (cell_w + cell_gap)
      local mid_x    = bx + cell_w * 0.5
      local text_y   = mn.y + (ih - fh) * 0.5

      -- Подчёркивание-ячейка
      dl:AddLine(
        imgui.ImVec2(bx,          mx.y - 2),
        imgui.ImVec2(bx + cell_w, mx.y - 2),
        c32(0.92, 0.92, 0.92, has_char and 0.55 or (is_active and 0.18 or 0)), 1.5)

      if has_char then
        local tw = imgui.CalcTextSize(char).x
        dl:AddText(imgui.ImVec2(mid_x - tw*0.5, text_y), c32(0.92,0.92,0.92,0.95), char)
      else
        -- Мигающий курсор в текущей активной ячейке
        if is_active and i == #tok_str + 1 then
          if math.floor(os.clock() * 2) % 2 == 0 then
            dl:AddRectFilled(
              imgui.ImVec2(mid_x - 1, text_y + 2),
              imgui.ImVec2(mid_x + 1, text_y + fh - 2),
              c32(0.92,0.92,0.92,0.70))
          end
        end
      end
    end

    imgui.PopFont()

    -- Ctrl+V — вставка из буфера обмена
    if is_active and imgui.IsKeyPressed(imgui.Key.V) and (imgui.IsKeyDown(imgui.Key.LeftCtrl) or imgui.IsKeyDown(imgui.Key.RightCtrl)) then
      local clip = imgui.GetClipboardText()
      if clip then
        local s = (str(B.token) .. clip):gsub('[^0-9]', '')
        setbuf(B.token, s:sub(1, 6))
      end
    end

    if changed then
      local s = str(B.token):gsub('[^0-9]', '')
      setbuf(B.token, s:sub(1, 6))
    end
    imgui.Spacing()

    if err_msg then
      errorText(err_msg)
      imgui.Spacing()
    end

    imgui.Spacing()
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    imgui.Spacing()

    local tok     = str(B.token)
    local tok_ok  = #tok == 6
    if loading then
      loaderDots('Подключение')
      imgui.Spacing()
    elseif fullBtn('Привязать аккаунт', not tok_ok) then
      local n_val = local_nick or ''
      local t_val = tok
      loading = true; err_msg = nil
      api('POST', '/api/samp/link', { token = t_val, nick = n_val }, nil, function(data, er)
        loading = false
        if er then
          err_msg = (er == 'Invalid or expired token')
            and 'Токен недействителен или истёк. Получите новый через /samp link'
            or er
        else
          auth = data.auth_token; nick = n_val
          saveConfig()
          setbuf(B.nick, ''); setbuf(B.token, '')
          err_msg = nil; show_auth = false; screen = 'subdivisions'
          fetchUserAvatar()
          fetchActiveCallouts()
        end
      end)
    end

    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.06, 0.06, 0.06, 0.60))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.14, 0.14, 0.14, 0.80))
    if imgui.Button('Назад', imgui.ImVec2(imgui.GetContentRegionAvail().x, 30)) then
      show_auth = false; err_msg = nil
    end
    imgui.PopStyleColor(2)
  end

  imgui.Spacing()
  drawDiscordFooter()
  imgui.Spacing()
  imgui.End()
end

-- ═══════════════════════════════════════════════════════════
--  ЗАГРУЗКА ТЕКСТУР ПО URL
-- ═══════════════════════════════════════════════════════════

local function urlEncode(s)
  return s:gsub('([^%w%-%.%_%~])', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
end

local TEX_CACHE_DIR = getWorkingDirectory() .. '/config/tex_cache'

local function clearFactionCache()
  subs = {}; subs_fetched_at = 0; factions_list = {}
  fact_textures = {}; fact_tex_loading = {}; fact_tex_queue = {}
  user_avatar_url = nil
  local kept = {}
  for _, r in ipairs(http_queue) do
    if not r.is_tex then kept[#kept + 1] = r end
  end
  http_queue = kept
  _card_lift = {}; _btn_lift = {}
  sub_view = 'factions'; sel_faction = nil; sel_id = nil
  -- Список активных каллаутов привязан к аккаунту → сбрасываем при выходе
  active_callouts = {}; sel_callout = nil
  toasts = {}; ac_prev_status = {}; ac_primed = false
end

local function loadTextureFromUrl(url)
  if not url or fact_textures[url] or fact_tex_loading[url] then return end
  fact_tex_loading[url] = true
  local slug       = url:gsub('[^%w]', ''):sub(-24)
  local cache_path = TEX_CACHE_DIR .. '/ftex_' .. slug .. '.bin'

  -- Файл уже закэширован — сразу передаём в очередь создания D3D-текстуры
  if doesFileExist(cache_path) then
    fact_tex_queue[#fact_tex_queue + 1] = { url = url, path = cache_path }
    fact_tex_loading[url] = false
    return
  end

  -- Ставим в общую HTTP-очередь как tex-запрос
  http_queue[#http_queue + 1] = {
    is_tex     = true,
    method     = 'GET',
    url        = CFG.bot_url .. '/api/samp/image-proxy?url=' .. urlEncode(url),
    hdrs       = { ['Authorization'] = 'Bearer ' .. (auth or ''), ['Connection'] = 'close' },
    body       = nil,
    tex_url    = url,
    cache_path = cache_path,
    cb         = nil,
  }
end

-- Обрабатывает один HTTP-запрос из очереди асинхронно:
-- effil.thread (OS-поток) делает сам запрос,
-- lua_thread (зелёный поток) ждёт результата через wait() не блокируя игру.
local function processNextHttp()
  if #http_queue == 0 or http_in_flight then return end
  local req = table.remove(http_queue, 1)
  http_in_flight = true

  local function finishTex(ok_req, code, body)
    if ok_req and (code == 200 or code == 206) and body and #body > 100 then
      if ok_lfs then
        lfs.mkdir(getWorkingDirectory() .. '/config')
        lfs.mkdir(TEX_CACHE_DIR)
      end
      local f = io.open(req.cache_path, 'wb')
      if f then
        local ok_w = pcall(function() f:write(body) end)
        f:close()
        if ok_w then
          fact_tex_queue[#fact_tex_queue + 1] = { url = req.tex_url, path = req.cache_path }
        end
      end
    end
    fact_tex_loading[req.tex_url] = false
  end

  local function finishApi(ok_req, code, body)
    local parsed = json.decode(body or '') or {}
    local d, e
    if not ok_req      then e = 'Ошибка соединения'
    elseif code == 401 then e = 'UNAUTHORIZED'
    elseif code > 201  then e = parsed.error or ('HTTP ' .. tostring(code))
    else                    d = parsed
    end
    if req.cb then pcall(req.cb, d, e) end
  end

  lua_thread.create(function()
      -- Извлекаем только примитивы для передачи в effil
      local method = req.method
      local url    = req.url
      local body   = req.body
      local auth   = req.hdrs['Authorization']
      local ct     = req.hdrs['Content-Type']
      local cl     = req.hdrs['Content-Length']
      local ver    = req.hdrs['X-Script-Version']

      local t
      local ok = pcall(function()
        -- Тело воркера живёт в плейн-модуле saes_callout.httpworker (см. --@PLAIN-BEGIN):
        -- effil.thread сериализует его через string.dump в отдельный OS-поток.
        t = effil.thread(httpWorker)(method, url, auth, ct, cl, body, ver)

        -- Ждём результата, уступая управление каждые 10мс.
        -- ВАЖНО: опрашиваем, пока статус НЕ станет терминальным, а НЕ пока
        -- он == 'running'. На первом (холодном) спавне effil поток не успевает
        -- перейти в 'running' к первой проверке → старый цикл пропускался целиком,
        -- и блокирующий t:get() морозил поток игры на всё время запроса (~1.2с).
        -- t:get() зовём только у завершённого потока — тогда он не блокирует.
        -- Запас 7с: socket сам отвалится за 5с, +2с буфер.
        local function terminal(s)
          return s == 'completed' or s == 'failed' or s == 'cancelled'
        end
        local deadline = os.clock() + 7
        while not terminal(t:status()) do
          if os.clock() > deadline then
            pcall(function() t:cancel() end)
            if req.is_tex then fact_tex_loading[req.tex_url] = false
            elseif req.cb then pcall(req.cb, nil, 'Ошибка соединения') end
            return
          end
          wait(10)
        end

        local ok_get, ok_req, code, resp = pcall(function() return t:get() end)
        if req.is_tex then
          finishTex(ok_get and ok_req, code, resp)
        else
          finishApi(ok_get and ok_req, code, resp)
        end
      end)

      -- Любая ошибка внутри корутины не должна оставить флаг висеть навсегда
      if not ok then
        pcall(function() if t then t:cancel() end end)
        if req.is_tex then fact_tex_loading[req.tex_url] = false
        elseif req.cb then pcall(req.cb, nil, 'Ошибка соединения') end
      end
      http_in_flight = false
  end)
end

-- Запрашивает аватар пользователя один раз после авторизации
-- (определена после loadTextureFromUrl — иначе upvalue не захватывается)
fetchUserAvatar = function()
  -- Уже есть URL или запрос в полёте — не дёргаем повторно. При ошибке
  -- user_avatar_url остаётся nil → следующий вызов (открытие окна) повторит.
  if not auth or type(user_avatar_url) == 'string' or avatar_fetching then return end
  avatar_fetching = true
  api('GET', '/api/samp/me', nil, auth, function(data, er)
    avatar_fetching = false
    if data and data.avatar_url then
      user_avatar_url = data.avatar_url
      loadTextureFromUrl(user_avatar_url)
    end
  end)
end

-- Построить список карточек-сущностей: ровно те, что показывает «New Incident» в Discord.
-- Каждый элемент API — это отдельная цель запроса: либо фракция целиком (дефолтное
-- подразделение, его имя = имя фракции), либо отдельное подразделение. Бэкенд уже
-- отфильтровал недоступные, поэтому здесь группировки по фракциям нет.
local function buildFactionsList(raw)
  local res = {}
  for _, s in ipairs(raw) do
    res[#res + 1] = {
      id          = s.id,                                              -- subdivision_id для отправки
      name        = s.name or s.faction_name or '?',
      logo_url    = s.logo_url or s.faction_logo_url,
      description = s.short_description or s.description or s.faction_description,  -- краткое
      full_desc   = s.embed_description or s.faction_description,                   -- полное
      subs        = { s },
    }
  end
  return res
end

-- ═══════════════════════════════════════════════════════════
--  АКТИВНЫЕ КАЛЛАУТЫ (server-driven: автор = привязанный аккаунт)
-- ═══════════════════════════════════════════════════════════

-- ImU32 цвет, НЕ зависящий от anim_alpha окна (тосты рисуются поверх игры всегда)
local function tc32(r, g, b, a)
  local ri = math.min(255, math.floor(r * 255 + 0.5))
  local gi = math.min(255, math.floor(g * 255 + 0.5))
  local bi = math.min(255, math.floor(b * 255 + 0.5))
  local ai = math.min(255, math.floor(a * 255 + 0.5))
  return ai * 16777216 + bi * 65536 + gi * 256 + ri
end

-- Типы тостов: акцентный цвет рамки/полосы, цвет/иконка/заголовок и глагол для тела.
-- accepted — приняли каллаут, resumed — возобновили реагирование, declined — отклонили.
local TOAST_KIND = {
  accepted = { acc = {0.35, 0.78, 0.42}, tit = {0.40, 0.85, 0.48},
               icon = 'ICON_CHECK',   title = 'Каллаут принят',
               verb = 'отреагировало на инцидент.' },
  resumed  = { acc = {0.35, 0.62, 0.95}, tit = {0.45, 0.68, 0.97},
               icon = 'ICON_REFRESH', title = 'Реагирование возобновлено',
               verb = 'возобновило реагирование.' },
  declined = { acc = {0.86, 0.32, 0.32}, tit = {0.92, 0.42, 0.42},
               icon = 'ICON_X',       title = 'Запрос отклонён',
               verb = 'отклонило запрос поддержки.' },
  cancelled = { acc = {0.95, 0.62, 0.28}, tit = {0.96, 0.70, 0.40},
               icon = 'ICON_ARROW_BACK_UP', title = 'Реагирование отменено',
               verb = 'отменило реагирование.' },
}

-- Добавить тост-оповещение + проиграть звук
local function pushToast(t)
  t.born = os.clock()
  toasts[#toasts + 1] = t
  while #toasts > 4 do table.remove(toasts, 1) end
  if t.logo_url then loadTextureFromUrl(t.logo_url) end
  playNotifySound()
end

-- Есть ли каллауты, за которыми стоит следить в фоне (могут стать «принят»)
local function hasWatchableCallouts()
  for _, c in ipairs(active_callouts) do
    if c.status == 'pending' or c.status == 'declined' then return true end
  end
  return false
end

-- Нарисовать тосты на foreground draw list — поверх всего, без захвата ввода.
-- Каждый: лого фракции, «Каллаут принят», название + краткое описание. Слайд справа.
local function drawToasts()
  if #toasts == 0 then return end
  local sw, sh = getScreenResolution()
  local dl  = imgui.GetForegroundDrawList()
  local now = os.clock()
  local cw, ch, mgn, gap = 330, 80, 18, 10
  local y = sh * 0.16
  imgui.PushFont(fnt_reg)
  local i = 1
  while i <= #toasts do
    local t   = toasts[i]
    local age = now - t.born
    if age >= TOAST_DUR then
      table.remove(toasts, i)
    else
      -- Слайд-ин в начале, слайд-аут в конце; k=0..1 — общая «видимость»
      local appin  = smoothstep(math.min(1, age / TOAST_ANIM))
      local appout = 1 - smoothstep(math.max(0, (age - (TOAST_DUR - TOAST_ANIM)) / TOAST_ANIM))
      local a      = math.min(appin, appout)
      local slide  = (1 - a) * (cw + mgn)
      local x2 = sw - mgn + slide
      local x1 = x2 - cw
      local y1, y2 = y, y + ch
      local k  = TOAST_KIND[t.kind] or TOAST_KIND.accepted
      local ac = k.acc   -- акцентный цвет (рамка/полоса/иконка) по типу оповещения

      dl:AddRectFilled(imgui.ImVec2(x1, y1 + 4), imgui.ImVec2(x2, y2 + 4), tc32(0, 0, 0, 0.35 * a), 12, 15)
      dl:AddRectFilled(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2), tc32(0.07, 0.07, 0.08, 0.97 * a), 12, 15)
      dl:AddRect(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2), tc32(ac[1], ac[2], ac[3], 0.55 * a), 12, 15, 1)
      dl:AddRectFilled(imgui.ImVec2(x1, y1 + 12), imgui.ImVec2(x1 + 4, y2 - 12), tc32(ac[1], ac[2], ac[3], 0.95 * a))

      -- Лого фракции (или плейсхолдер с буквой)
      local lsz = ch - 26
      local lx  = x1 + 16
      local ly  = y1 + (ch - lsz) * 0.5
      local tex = t.logo_url and fact_textures[t.logo_url]
      if tex then
        dl:AddImageRounded(tex, imgui.ImVec2(lx, ly), imgui.ImVec2(lx + lsz, ly + lsz),
          imgui.ImVec2(0, 0), imgui.ImVec2(1, 1), tc32(1, 1, 1, a), 8, 15)
      else
        dl:AddRectFilled(imgui.ImVec2(lx, ly), imgui.ImVec2(lx + lsz, ly + lsz), tc32(0.18, 0.18, 0.20, a), 8, 15)
        imgui.PushFont(fnt_big)
        local ab = (t.subdivision or '?'):sub(1, 1)
        local aw, afh = imgui.CalcTextSize(ab).x, imgui.GetFontSize()
        dl:AddText(imgui.ImVec2(lx + lsz * 0.5 - aw * 0.5, ly + lsz * 0.5 - afh * 0.5), tc32(0.55, 0.55, 0.58, a), ab)
        imgui.PopFont()
      end

      local tx = lx + lsz + 12
      dl:PushClipRect(imgui.ImVec2(tx, y1), imgui.ImVec2(x2 - 12, y2), true)
      imgui.PushFont(fnt_bold)
      local bfh  = imgui.GetFontSize()
      -- Иконка типа (галочка/крест/обновление) — «пожирнее» за счёт многократной
      -- отрисовки со смещением; затем заголовок акцентным цветом.
      local icon = tbi(k.icon)
      local ix   = tx
      if icon ~= '' then
        local icol = tc32(ac[1], ac[2], ac[3], a)
        for _, o in ipairs({ {0,0}, {0.7,0}, {0,0.7}, {0.7,0.7} }) do
          dl:AddText(imgui.ImVec2(tx + o[1], y1 + 13 + o[2]), icol, icon)
        end
        ix = tx + imgui.CalcTextSize(icon).x + 7
      end
      dl:AddText(imgui.ImVec2(ix, y1 + 13), tc32(k.tit[1], k.tit[2], k.tit[3], a), k.title)
      imgui.PopFont()
      if t.body and t.body ~= '' then
        dl:AddText(imgui.ImVec2(tx, y1 + 13 + bfh + 5), tc32(0.92, 0.92, 0.92, 0.96 * a), t.body)
      end
      if t.sub and t.sub ~= '' then
        dl:AddText(imgui.ImVec2(tx, y1 + 13 + bfh + 5 + 18), tc32(0.55, 0.55, 0.58, a), t.sub)
      end
      dl:PopClipRect()

      y = y2 + gap
      i = i + 1
    end
  end
  imgui.PopFont()
end

-- Запросить список активных каллаутов пользователя с сервера и пересобрать
-- active_callouts. Вызывается при открытии окна, отправке, обновлении и раз в
-- AC_INTERVAL секунд (гейт интервала — в main loop). Защита от параллельных
-- запросов через ac_fetching.
fetchActiveCallouts = function()
  if not auth or ac_fetching then return end
  ac_fetching = true
  ac_fetch_at = os.clock()
  api('GET', '/api/samp/callouts', nil, auth, function(data, er)
    ac_fetching = false
    if er or type(data) ~= 'table' or type(data.callouts) ~= 'table' then return end
    local list = {}
    for _, it in ipairs(data.callouts) do
      local brief = it.brief_description
      if not brief or brief == '' then brief = it.description or '' end
      list[#list + 1] = {
        id               = it.id,
        faction_name     = it.subdivision_name or it.faction_name or '?',
        faction_logo_url = it.faction_logo_url,
        brief            = brief,
        description      = it.description,
        location         = it.location,
        tac              = it.tac_channel,
        subdivision_name = it.subdivision_name,
        -- created_at в абсолютном os.time: now − возраст с сервера (без TZ-проблем)
        created_at       = os.time() - (tonumber(it.age_seconds) or 0),
        status           = it.derived_status or 'pending',
        detail           = it,
      }
      if it.faction_logo_url then loadTextureFromUrl(it.faction_logo_url) end
    end

    -- Детект перехода в «принят» → оповещение со звуком (даже при закрытом меню).
    -- Первый фетч только формирует базлайн (ac_primed), чтобы не «дзинькать»
    -- на уже принятые до запуска скрипта каллауты.
    local new_prev = {}
    for _, c in ipairs(list) do
      local prev = ac_prev_status[c.id]
      -- Тип перехода статуса → оповещение (только после базлайна ac_primed):
      --   стал «принят» (был не принят) → accepted, либо resumed, если до этого declined
      --   стал «отклонён» (был не отклонён) → declined
      local kind
      if ac_primed then
        if c.status == 'declined' and prev ~= 'declined' then
          kind = 'declined'                       -- отклонили запрос поддержки
        elseif prev == 'declined' and (c.status == 'accepted' or c.status == 'pending') then
          kind = 'resumed'                        -- сняли отклонение (revive) → возобновление
        elseif c.status == 'accepted' and prev ~= 'accepted' then
          kind = 'accepted'                       -- появился отклик подразделения
        elseif c.status == 'pending' and prev == 'accepted' then
          kind = 'cancelled'                      -- сняли последний отклик → отмена реагирования
        end
      end
      if kind then
        local subname = c.subdivision_name or c.faction_name or ''
        local body, sub
        if kind == 'declined' then
          -- Детали отклонения берём напрямую из API (declined.by_name / reason)
          local dec = (type(c.detail) == 'table') and c.detail.declined or nil
          body = (dec and dec.by_name and dec.by_name ~= '')
                 and ('Отклонил: ' .. dec.by_name)
                 or  (subname .. ' отклонило запрос поддержки.')
          sub  = dec and dec.reason
        else
          body = subname .. ' ' .. (TOAST_KIND[kind] and TOAST_KIND[kind].verb or '')
          sub  = c.brief
        end
        pushToast({
          id          = c.id,
          kind        = kind,
          subdivision = subname,   -- для буквы-плейсхолдера, если нет лого
          body        = body,
          sub         = sub,
          logo_url    = c.faction_logo_url,
        })
      end
      new_prev[c.id] = c.status
    end
    ac_prev_status = new_prev
    ac_primed = true

    active_callouts = list
    -- Переустановить открытую карточку на свежий объект по id; если каллаут
    -- больше не активен — оставляем последний снимок, чтобы карточка не дёргалась.
    if sel_callout then
      for _, c in ipairs(active_callouts) do
        if c.id == sel_callout.id then sel_callout = c; break end
      end
    end
  end)
end

-- ═══════════════════════════════════════════════════════════
--  ЭКРАН: ПОДРАЗДЕЛЕНИЯ
-- ═══════════════════════════════════════════════════════════

-- ─── Карточка фракции ────────────────────────────────────────
local function drawFactionCard(f, idx, card_w, card_h)
  local dl  = imgui.GetWindowDrawList()
  local wp  = imgui.GetWindowPos()
  local cp  = imgui.GetCursorPos()
  local x1  = wp.x + cp.x
  local y1  = wp.y + cp.y
  local x2  = x1 + card_w
  local y2  = y1 + card_h
  local rad = 10

  -- Кнопка «Вызов» — квадрат справа (позиции до lift)
  local vbsz = card_h - 20
  local vbx1 = x2 - vbsz - 10
  local vby1 = y1 + 10
  local vbx2 = vbx1 + vbsz
  local vby2 = vby1 + vbsz

  -- Hover (до lift)
  local hov      = imgui.IsMouseHoveringRect(imgui.ImVec2(x1,y1),     imgui.ImVec2(x2,y2),     false)
  local vbtn_hov = imgui.IsMouseHoveringRect(imgui.ImVec2(vbx1,vby1), imgui.ImVec2(vbx2,vby2), false)
  local body_hov = hov and not vbtn_hov

  -- Lift по всей карточке (в т.ч. когда курсор на кнопке — ховер карточки продолжается)
  local key = 'fc'..idx
  _card_lift[key] = (_card_lift[key] or 0)
  _card_lift[key] = _card_lift[key] + ((hov and 1 or 0) - _card_lift[key]) * 0.14
  local lift = _card_lift[key] * 3
  y1 = y1 - lift; y2 = y2 - lift

  -- Фон карточки
  dl:AddRectFilled(imgui.ImVec2(x1,y1), imgui.ImVec2(x2,y2),
    c32(0.08,0.08,0.08, hov and 1.0 or 0.85), rad, 15)

  -- Лого слева (всегда чёткое)
  local lsz = card_h - 32
  local lx  = x1 + 14
  local ly  = y1 + (card_h - lsz) * 0.5
  local tex = f.logo_url and fact_textures[f.logo_url]
  if tex then
    dl:AddImageRounded(tex,
      imgui.ImVec2(lx, ly), imgui.ImVec2(lx+lsz, ly+lsz),
      imgui.ImVec2(0,0), imgui.ImVec2(1,1), c32(1,1,1, hov and 1.0 or 0.35), 8, 15)
  else
    dl:AddRectFilled(imgui.ImVec2(lx,ly), imgui.ImVec2(lx+lsz,ly+lsz), c32(0.18,0.18,0.18,1), 8, 15)
    imgui.PushFont(fnt_big)
    local abbr = (f.name or '?'):sub(1,1)
    local aw   = imgui.CalcTextSize(abbr).x
    local afh  = imgui.GetFontSize()
    dl:AddText(imgui.ImVec2(lx+lsz*0.5-aw*0.5, ly+lsz*0.5-afh*0.5), c32(0.92,0.92,0.92,0.50), abbr)
    imgui.PopFont()
  end

  -- Красный левый акцент
  dl:AddRectFilled(imgui.ImVec2(x1, y1+rad), imgui.ImVec2(x1+3, y2-rad),
    c32(0.85, 0.10, 0.10, hov and 0.90 or 0.55))

  -- Текст (обрезаем до кнопки)
  local tx      = x1 + 14 + lsz + 14
  local clip_x2 = vbx1 - 8
  dl:PushClipRect(imgui.ImVec2(tx, y1), imgui.ImVec2(clip_x2, y2), true)
  imgui.PushFont(fnt_big)
  local name_fh = imgui.GetFontSize()
  dl:AddText(imgui.ImVec2(tx, y1 + 18), c32(0.92,0.92,0.92,0.95), f.name or '?')
  imgui.PopFont()
  if f.description and f.description ~= '' then
    dl:AddTextFontPtr(imgui.GetFont(), imgui.GetFontSize(),
      imgui.ImVec2(tx, y1 + 18 + name_fh + 5),
      c32(0.50,0.50,0.53,1), f.description, nil, clip_x2 - tx, nil)
  end
  dl:PopClipRect()

  -- Кнопка «Вызов» (с lift)
  local bx1 = vbx1;  local by1 = vby1 - lift
  local bx2 = vbx2;  local by2 = vby2 - lift
  local btn_bg = vbtn_hov and c32(0.72,0.08,0.08,1) or c32(0.18,0.18,0.20,0.18)
  dl:AddRectFilled(imgui.ImVec2(bx1,by1), imgui.ImVec2(bx2,by2), btn_bg, 8, 15)

  -- Иконка колокольчика (один и тот же глиф при наведении и без)
  local bell_g = (ok_ti and tbi('ICON_BELL_FILLED') ~= '' and tbi('ICON_BELL_FILLED')) or '!'
  imgui.PushFont(fnt_ti_lg)
  local bw  = imgui.CalcTextSize(bell_g).x
  local bfh = imgui.GetFontSize()
  imgui.PopFont()
  local lbl  = 'Вызов'
  local lfh  = imgui.GetFontSize()
  local lw   = imgui.CalcTextSize(lbl).x
  local blk_h = bfh + 4 + lfh
  local blk_y = by1 + (vbsz - blk_h) * 0.5
  local icon_a = vbtn_hov and 0.92 or 0.22
  local lbl_a  = vbtn_hov and 0.75 or 0.22

  imgui.PushFont(fnt_ti_lg)
  dl:AddText(imgui.ImVec2((bx1+bx2)*0.5 - bw*0.5, blk_y),       c32(1,1,1,icon_a), bell_g)
  imgui.PopFont()
  dl:AddText(imgui.ImVec2((bx1+bx2)*0.5 - lw*0.5, blk_y+bfh+4), c32(1,1,1,lbl_a),  lbl)

  local body_click = body_hov  and imgui.IsMouseClicked(0)
  local vbtn_click = vbtn_hov  and imgui.IsMouseClicked(0)
  imgui.Dummy(imgui.ImVec2(card_w, card_h))
  return body_click, vbtn_click
end

-- ─── Список подразделений фракции ────────────────────────────
-- Цель каллаута — всегда первое подразделение фракции (выбора из нескольких больше нет)
local function selectFirstSub(f)
  sel_id = (f and f.subs and #f.subs > 0) and f.subs[1].id or nil
end

-- ─── Красная кнопка ──────────────────────────────────────────
local function redBtn(label)
  local avail = imgui.GetContentRegionAvail().x
  local h     = 44
  local cp    = imgui.GetCursorPos()
  local wp    = imgui.GetWindowPos()
  local dl    = imgui.GetWindowDrawList()
  local x1    = wp.x + cp.x
  local y1    = wp.y + cp.y
  local x2    = x1 + avail
  local y2    = y1 + h
  local rad   = 6

  local clicked = imgui.InvisibleButton('##rb_'..label, imgui.ImVec2(avail, h))
  local act     = imgui.IsItemActive()

  local r = act and 0.55 or 0.62
  dl:AddRectFilled(imgui.ImVec2(x1,y1), imgui.ImVec2(x2,y2), c32(r,0.08,0.08,1), rad, 15)

  -- Блик сверху
  dl:AddRectFilledMultiColor(
    imgui.ImVec2(x1,y1), imgui.ImVec2(x2, y1+h*0.45),
    c32(1,1,1,0.08), c32(1,1,1,0.08), c32(1,1,1,0), c32(1,1,1,0))

  local tw = imgui.CalcTextSize(label).x
  local fh = imgui.GetFontSize()
  dl:AddText(imgui.ImVec2(x1+(avail-tw)*0.5, y1+(h-fh)*0.5), c32(1,1,1,0.95), label)

  return clicked
end

-- ─── Панель «Активные каллауты» ──────────────────────────────
-- Строка: крупное лого фракции, название (жирно) + краткое описание,
-- бейдж статуса сверху и длительность ПОД ним (не накладываются).
-- Клик открывает полную карточку.
local function drawActiveCalloutRow(c)
  local w  = imgui.GetContentRegionAvail().x
  local h  = 72
  local clicked = imgui.InvisibleButton('##ac_' .. tostring(c.id), imgui.ImVec2(w, h))
  local hov = imgui.IsItemHovered()
  local mn  = imgui.GetItemRectMin()
  local mx  = imgui.GetItemRectMax()
  local dl  = imgui.GetWindowDrawList()

  -- Фон + левый красный акцент
  dl:AddRectFilled(mn, mx, c32(0.10, 0.10, 0.10, hov and 1.0 or 0.72), 10, 15)
  dl:AddRectFilled(imgui.ImVec2(mn.x, mn.y + 8), imgui.ImVec2(mn.x + 4, mx.y - 8),
    c32(0.85, 0.10, 0.10, hov and 0.95 or 0.55))

  -- Лого фракции (в 2 раза крупнее прежнего) или плейсхолдер с буквой
  local lsz = h - 16   -- 56px
  local lx  = mn.x + 12
  local ly  = mn.y + (h - lsz) * 0.5
  local tex = c.faction_logo_url and fact_textures[c.faction_logo_url]
  if tex then
    dl:AddImageRounded(tex, imgui.ImVec2(lx, ly), imgui.ImVec2(lx + lsz, ly + lsz),
      imgui.ImVec2(0, 0), imgui.ImVec2(1, 1), c32(1, 1, 1, hov and 1.0 or 0.70), 9, 15)
  else
    dl:AddRectFilled(imgui.ImVec2(lx, ly), imgui.ImVec2(lx + lsz, ly + lsz), c32(0.18, 0.18, 0.20, 1), 9, 15)
    imgui.PushFont(fnt_big)
    local ab = (c.faction_name or '?'):sub(1, 1)
    local aw, afh = imgui.CalcTextSize(ab).x, imgui.GetFontSize()
    dl:AddText(imgui.ImVec2(lx + lsz * 0.5 - aw * 0.5, ly + lsz * 0.5 - afh * 0.5), c32(0.55, 0.55, 0.58, 1), ab)
    imgui.PopFont()
  end

  -- Правая колонка: только бейдж статуса (время вынесено в левую колонку строкой)
  local meta = statusMeta(c.status)
  imgui.PushFont(fnt_bold)
  local pill   = meta.label
  local pfh    = imgui.GetFontSize()
  local pill_w = imgui.CalcTextSize(pill).x + 18
  local pill_h = 22
  local px2    = mx.x - 12
  local px1    = px2 - pill_w
  local py1    = mn.y + 12
  dl:AddRectFilled(imgui.ImVec2(px1, py1), imgui.ImVec2(px2, py1 + pill_h), c32(meta.r, meta.g, meta.b, 0.20), 11, 15)
  dl:AddRect(imgui.ImVec2(px1, py1), imgui.ImVec2(px2, py1 + pill_h), c32(meta.r, meta.g, meta.b, 0.50), 11, 15, 1)
  dl:AddText(imgui.ImVec2((px1 + px2) * 0.5 - imgui.CalcTextSize(pill).x * 0.5, py1 + (pill_h - pfh) * 0.5),
    c32(meta.r, meta.g, meta.b, 1.0), pill)
  imgui.PopFont()

  -- Левая колонка: название (крупно) + краткое описание + «Создан N назад» (живой).
  -- Обрезаем до начала бейджа, чтобы строки не залезли под него.
  local tx = lx + lsz + 14
  local right_col_x = px1 - 12
  dl:PushClipRect(imgui.ImVec2(tx, mn.y), imgui.ImVec2(right_col_x, mx.y), true)
  imgui.PushFont(fnt_big)
  dl:AddText(imgui.ImVec2(tx, mn.y + 7), c32(0.95, 0.95, 0.95, 1.0), c.faction_name or '?')
  imgui.PopFont()
  local liney = mn.y + 7 + 24
  local brief = c.brief or ''
  if brief ~= '' then
    imgui.PushFont(fnt_bold)
    dl:AddText(imgui.ImVec2(tx, liney), c32(0.62, 0.62, 0.65, 1), brief)
    imgui.PopFont()
    liney = liney + 19
  end
  imgui.PushFont(fnt_reg)
  dl:AddText(imgui.ImVec2(tx, liney), c32(0.50, 0.50, 0.53, 1),
    'Создан ' .. fmtAgo(os.time() - (c.created_at or os.time())))
  imgui.PopFont()
  dl:PopClipRect()

  return clicked
end

local function drawActiveCalloutsPanel()
  imgui.PushFont(fnt_bold)
  imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.58, 1))
  imgui.Text((tbi('ICON_BELL_RINGING') ~= '' and (tbi('ICON_BELL_RINGING') .. ' ') or '')
    .. 'Активные каллауты (' .. #active_callouts .. ')')
  imgui.PopStyleColor()
  imgui.PopFont()
  imgui.Spacing()

  local row_h   = 72
  local gap     = 6
  local cap     = 3   -- видимых строк без прокрутки; остальные — колесом мыши
  local shown   = math.min(#active_callouts, cap)
  local panel_h = shown * (row_h + gap)

  imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
  imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, gap))
  if imgui.BeginChild('##acpanel', imgui.ImVec2(-1, panel_h), false, imgui.WindowFlags.NoScrollbar) then
    for _, c in ipairs(active_callouts) do
      if drawActiveCalloutRow(c) then
        sel_callout = c
        screen = 'callout_card'
      end
    end
  end
  imgui.EndChild()
  imgui.PopStyleVar()
  imgui.PopStyleColor()

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()
end

-- ─── Главный экран подразделений ─────────────────────────────
local function drawSubdivisions()
  local sw, sh = getScreenResolution()
  applyWindowPos()
  -- Динамический минимум высоты: заголовок + 1 карточка + пагинация + футер (~300),
  -- плюс высота панели активных каллаутов, если она показывается. Иначе при сужении
  -- список фракций налезал бы на нижнюю строку (аватар/«Выйти»).
  local min_h = 300
  if sub_view == 'factions' and #active_callouts > 0 then
    min_h = min_h + 41 + math.min(#active_callouts, 3) * 78  -- лейбл+отступы + строки
  end
  applyWindowSize('subdivisions', min_h)
  -- NoScrollbar/NoScrollWithMouse: список фракций — постраничный, рисуется абсолютными
  -- координатами; нативный скролл сбил бы позиции. Высота окна теперь задаётся юзером.
  local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
              + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
  if not imgui.Begin('##subs', visible, flags) then imgui.End(); return end
  trackWindowPos(); trackWindowSize('subdivisions')
  drawGrid(); drawDecor(); drawCloseBtn(); drawSettingsBtn()

  -- Загрузка при необходимости
  if #subs == 0 and not loading then
    loading = true
    api('GET', '/api/samp/subdivisions', nil, auth, function(data, er)
      loading = false
      if er == 'UNAUTHORIZED' then
        auth = nil; nick = nil; clearFactionCache(); screen = 'token'; os.remove(CFG.cfg_file)
      elseif er then
        err_msg = cleanMsg(er)
      else
        subs = data.subdivisions or {}
        subs_fetched_at = os.clock()  -- отметка для TTL-кэша
        factions_list = buildFactionsList(subs)
        faction_page = 1
        for _, f in ipairs(factions_list) do loadTextureFromUrl(f.logo_url) end
        err_msg = nil
      end
    end)
  end

  -- ── Шапка ──────────────────────────────────────────────────
  if sub_view == 'detail' and sel_faction then
    -- Кнопка назад
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.08,0.08,0.08,0.60))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.20,0.20,0.20,0.80))
    if imgui.SmallButton(tbi('ICON_ARROW_BACK_UP') .. ' Назад') then
      sub_view = 'factions'; sel_id = nil
    end
    imgui.PopStyleColor(2)
    imgui.Spacing()

    -- Блок: красная полоса + лого + название + краткое описание
    do
      local dl      = imgui.GetWindowDrawList()
      local wp2     = imgui.GetWindowPos()
      local lsz     = 64
      local bar_w   = 4
      local bar_gap = 10
      local left_w  = bar_w + bar_gap + lsz  -- ширина левой колонки

      local cp_s = imgui.GetCursorPos()

      -- Левая колонка: Dummy резервирует место для лого
      imgui.Dummy(imgui.ImVec2(left_w, lsz))
      imgui.SameLine(0, 14)

      -- Правая колонка: название + краткое описание
      imgui.BeginGroup()

      imgui.PushFont(fnt_bold)
      imgui.PushStyleColor(imgui.Col.Text, FG)
      imgui.Text(sel_faction.name or '')
      imgui.PopStyleColor()
      imgui.PopFont()

      local short_desc = sel_faction.description or ''
      if short_desc ~= '' then
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50, 0.50, 0.53, 1))
        imgui.TextWrapped(short_desc)
        imgui.PopStyleColor()
      end

      imgui.EndGroup()

      -- DrawList: красная полоса и лого поверх Dummy-области
      local ly    = wp2.y + cp_s.y
      local lx    = wp2.x + cp_s.x + bar_w + bar_gap
      local blk_h = imgui.GetCursorPosY() - cp_s.y

      dl:AddRectFilled(
        imgui.ImVec2(wp2.x + cp_s.x,         ly + 4),
        imgui.ImVec2(wp2.x + cp_s.x + bar_w, ly + blk_h - 4),
        c32(0.85, 0.10, 0.10, 0.90), 2, 15)

      local ftex = sel_faction.logo_url and fact_textures[sel_faction.logo_url]
      if ftex then
        dl:AddImageRounded(ftex,
          imgui.ImVec2(lx, ly), imgui.ImVec2(lx+lsz, ly+lsz),
          imgui.ImVec2(0,0), imgui.ImVec2(1,1), c32(1,1,1,1), 10, 15)
      else
        local cx, cy = lx+lsz*0.5, ly+lsz*0.5
        dl:AddCircleFilled(imgui.ImVec2(cx,cy), lsz*0.5, c32(0.18,0.18,0.20,1), 32)
        imgui.PushFont(fnt_big)
        local ab = (sel_faction.name or '?'):sub(1,1)
        local aw, ah = imgui.CalcTextSize(ab).x, imgui.GetFontSize()
        dl:AddText(imgui.ImVec2(cx-aw*0.5, cy-ah*0.5), c32(0.55,0.55,0.58,1), ab)
        imgui.PopFont()
      end
    end
    imgui.Spacing()
  else
    -- Только заголовок (ник + Выйти перенесены в нижний правый угол)
    imgui.PushFont(fnt_big)
    shadowText('Фракции / Подразделения', 0.50)
    imgui.PopFont()
  end
  imgui.Separator()
  imgui.Spacing()

  -- ── Панель «Активные каллауты» (над списком фракций) ────────
  if sub_view == 'factions' and #active_callouts > 0 then
    drawActiveCalloutsPanel()
  end

  -- ── Контент ────────────────────────────────────────────────
  if loading then
    loaderDots('Загрузка...')
  elseif err_msg then
    errorText(err_msg)
  elseif sub_view == 'factions' then
    -- ── Список фракций (с пагинацией) ────────────────────────
    if #factions_list == 0 then
      mutedText('  Нет доступных подразделений.')
    else
      local cards_top = imgui.GetCursorPosY()
      local card_w  = imgui.GetContentRegionAvail().x
      local card_h  = 90
      local gap     = 2
      local row_h   = card_h + gap
      local pg_bar  = 44   -- резерв под панель пагинации (Spacing + кнопка)
      local foot_h  = 52   -- резерв под нижнюю строку (аватар + «Выйти»)

      -- Окно теперь свободно ресайзится пользователем — считаем по ФАКТИЧЕСКОМУ
      -- остатку высоты до низа окна, минус резерв под нижнюю строку (аватар/Выйти).
      -- Панель активных каллаутов выше уже «съела» свою высоту → авто-учёт.
      local avail_h = math.max(row_h, imgui.GetContentRegionAvail().y - foot_h)

      -- Сколько карточек влезает целиком (у последней нет нижнего отступа)
      local fit_all = math.max(1, math.floor((avail_h + gap) / row_h))

      local show_pg, FPER
      if #factions_list <= fit_all then
        show_pg = false
        FPER    = fit_all
      else
        show_pg = true
        FPER    = math.max(1, math.floor((avail_h - pg_bar + gap) / row_h))
      end

      local total_p = math.ceil(#factions_list / FPER)
      faction_page  = math.max(1, math.min(faction_page, total_p))
      local p_start = (faction_page - 1) * FPER + 1
      local p_end   = math.min(faction_page * FPER, #factions_list)

      -- Высота дочернего окна строго под видимые карточки — без пустого места
      local cards_shown = p_end - p_start + 1
      local content_h   = cards_shown * row_h - gap

      imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
      -- Нулевой паддинг дочернего окна + вертикальный зазор ровно = gap:
      -- так высота строки строго card_h + gap, без скрытого ItemSpacing между Dummy
      imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
      imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing,   imgui.ImVec2(0, gap))
      -- NoScrollbar/NoScrollWithMouse: карточки рисуются абсолютными координатами,
      -- нативный скролл сбил бы их позиции — листаем строго постранично
      if imgui.BeginChild('##fcards', imgui.ImVec2(-1, content_h), false,
            imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse) then
        for i = p_start, p_end do
          local f = factions_list[i]
          local body_click, callout_click = drawFactionCard(f, i, card_w, card_h)
          if callout_click then
            selectFirstSub(f)
            sel_faction = f; screen = 'callout'
            setbuf(B.brief,''); setbuf(B.desc,'')
            setbuf(B.loc,'');   setbuf(B.tac,'')
            err_msg = nil
          elseif body_click then
            sel_faction = f; sub_view = 'detail'
            sel_id = nil
          end
        end

        -- Колесо мыши листает страницы
        if show_pg and imgui.IsWindowHovered() then
          local wheel = imgui.GetIO().MouseWheel
          if wheel < 0 then
            faction_page = math.min(total_p, faction_page + 1)
          elseif wheel > 0 then
            faction_page = math.max(1, faction_page - 1)
          end
        end
      end
      imgui.EndChild()
      imgui.PopStyleVar(2)
      imgui.PopStyleColor()

      if show_pg then
        -- Прижимаем панель пагинации к низу области (над строкой аватар/«Выйти»),
        -- иначе при коротком списке кнопки висят высоко с большим пустым зазором.
        local pg_y = cards_top + avail_h - pg_bar
        if pg_y > imgui.GetCursorPosY() then imgui.SetCursorPosY(pg_y) end
        local avail   = imgui.GetContentRegionAvail().x
        local btn_w   = 70
        local lbl     = faction_page .. ' / ' .. total_p
        local lw      = imgui.CalcTextSize(lbl).x
        local group_w = btn_w * 2 + lw + 24
        imgui.SetCursorPosX(imgui.GetCursorPosX() + (avail - group_w) * 0.5)

        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.10,0.10,0.10,0.60))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.22,0.22,0.22,0.80))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.30,0.30,0.30,1.00))
        imgui.PushStyleColor(imgui.Col.Text, FG)
        -- Естественная высота кнопок (0) + AlignTextToFramePadding у подписи между ними
        -- даёт идеальное вертикальное выравнивание всего ряда
        if imgui.Button('Назад##pg', imgui.ImVec2(btn_w, 0)) and faction_page > 1 then
          faction_page = faction_page - 1
        end
        imgui.SameLine(0, 12)
        imgui.AlignTextToFramePadding()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50,0.50,0.53,1))
        imgui.Text(lbl)
        imgui.PopStyleColor()
        imgui.SameLine(0, 12)
        if imgui.Button('Вперёд##pg', imgui.ImVec2(btn_w, 0)) and faction_page < total_p then
          faction_page = faction_page + 1
        end
        imgui.PopStyleColor(4)
      end
    end

  else
    -- ── Детальный вид фракции ─────────────────────────────────
    -- Описание занимает всё место до кнопки + отступ под аватар
    local btn_area    = 72   -- separator + spacing*2 + button (44) + spacing
    local avatar_area = 44   -- строка аватара снизу
    local desc_h = imgui.GetContentRegionAvail().y - btn_area - avatar_area

    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
    if imgui.BeginChild('##fdesc', imgui.ImVec2(-1, math.max(desc_h, 10)), false) then
      local full = sel_faction and (sel_faction.full_desc or '')
      if full and full ~= '' then
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.62, 0.62, 0.65, 1))
        imgui.PushTextWrapPos(imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x)
        imgui.TextWrapped(full)
        imgui.PopTextWrapPos()
        imgui.PopStyleColor()
      end
    end
    imgui.EndChild()
    imgui.PopStyleColor()

    imgui.Separator()
    imgui.Spacing()
    imgui.PushFont(fnt_bold)
    if redBtn('Запросить помощь') then
      selectFirstSub(sel_faction)
      screen = 'callout'
      setbuf(B.brief,''); setbuf(B.desc,'')
      setbuf(B.loc,'');   setbuf(B.tac,'')
      err_msg = nil
    end
    imgui.PopFont()
  end

  -- ── Аватар + ник (нижний левый) и кнопка Выйти (нижний правый) ─────────────
  do
    local wp         = imgui.GetWindowPos()
    local ws         = imgui.GetWindowSize()
    local dl         = imgui.GetWindowDrawList()
    local fh         = imgui.GetFontSize()
    local pad        = 20          -- отступ от краёв окна
    local av_sz      = 22          -- размер аватара
    local row_y      = ws.y - pad - av_sz  -- y-позиция строки

    -- ─── Левая часть: аватар + ник ───────────────────────────────────────────
    local av_tex  = type(user_avatar_url) == 'string' and fact_textures[user_avatar_url]
    local av_cx   = wp.x + pad + av_sz * 0.5
    local av_cy   = wp.y + row_y + av_sz * 0.5
    local text_x  = pad + av_sz + 7

    -- Hover-детект по кружку аватара
    local av_hov  = imgui.IsMouseHoveringRect(
      imgui.ImVec2(wp.x + pad,         wp.y + row_y),
      imgui.ImVec2(wp.x + pad + av_sz, wp.y + row_y + av_sz), false)
    -- Плавная анимация масштаба (smoothstep lerp)
    local av_target = av_hov and 1.18 or 1.0
    av_hover_scale  = av_hover_scale + (av_target - av_hover_scale) * 0.18
    local av_r      = av_sz * 0.5 * av_hover_scale   -- радиус с учётом scale

    if av_tex then
      dl:AddImageRounded(av_tex,
        imgui.ImVec2(av_cx - av_r, av_cy - av_r),
        imgui.ImVec2(av_cx + av_r, av_cy + av_r),
        imgui.ImVec2(0,0), imgui.ImVec2(1,1), c32(1,1,1,0.92), av_r, 15)
    else
      -- Плейсхолдер: кружок с первой буквой ника
      dl:AddCircleFilled(imgui.ImVec2(av_cx, av_cy), av_r, c32(0.18,0.18,0.20,1), 32)
      dl:AddCircle(      imgui.ImVec2(av_cx, av_cy), av_r, c32(0.92,0.92,0.92,0.12), 32, 1)
      local letter = (nick or '?'):sub(1,1):upper()
      local lw = imgui.CalcTextSize(letter).x
      dl:AddText(imgui.ImVec2(av_cx - lw * 0.5, av_cy - fh * 0.5), c32(0.55,0.55,0.58,1), letter)
    end
    local nick_short = (nick or ''):sub(1, 14)
    dl:AddText(
      imgui.ImVec2(wp.x + text_x, wp.y + row_y + (av_sz - fh) * 0.5),
      c32(0.45, 0.45, 0.48, 1), nick_short)

    -- ─── Правая часть: кнопка Выйти ──────────────────────────────────────────
    local btn_txt = 'Выйти'
    local btn_w   = imgui.CalcTextSize(btn_txt).x
    local btn_x   = ws.x - pad - btn_w
    local bx1     = wp.x + btn_x - 6
    local by1     = wp.y + row_y + (av_sz - fh) * 0.5 - 4
    local bx2     = bx1 + btn_w + 12
    local by2     = by1 + fh + 8
    local hov     = imgui.IsMouseHoveringRect(imgui.ImVec2(bx1,by1), imgui.ImVec2(bx2,by2), false)
    if hov then
      dl:AddRectFilled(imgui.ImVec2(bx1,by1), imgui.ImVec2(bx2,by2),
        c32(0.18,0.18,0.18,0.90), 4, 15)
    end
    dl:AddText(imgui.ImVec2(wp.x + btn_x, wp.y + row_y + (av_sz - fh) * 0.5),
      hov and c32(0.92,0.92,0.92,1) or c32(0.55,0.55,0.57,1), btn_txt)

    if hov and imgui.IsMouseClicked(0) then
      auth = nil; nick = nil
      clearFactionCache()
      screen = 'token'; show_auth = false; err_msg = nil
      os.remove(CFG.cfg_file)
    end
  end

  imgui.Spacing()
  imgui.End()
end

-- ═══════════════════════════════════════════════════════════
--  ЭКРАН: ФОРМА КАЛЛАУТА
-- ═══════════════════════════════════════════════════════════

local function drawCallout()
  local sw, sh = getScreenResolution()
  applyWindowPos()
  applyWindowSize('callout')
  local flags = imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
  if not imgui.Begin('##call', visible, flags) then imgui.End(); return end
  trackWindowPos(); trackWindowSize('callout')
  drawDecor(); drawCloseBtn(); drawSettingsBtn()

  -- Шапка
  imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.08, 0.08, 0.08, 0.60))
  imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.20, 0.20, 0.20, 0.80))
  if imgui.SmallButton(tbi('ICON_ARROW_BACK_UP') .. ' Назад') then screen = 'subdivisions'; err_msg = nil end
  imgui.PopStyleColor(2)
  imgui.SameLine(0, 12)
  imgui.PushFont(fnt_bold)
  imgui.Text('Отправка запроса поддержки')
  imgui.PopFont()
  imgui.Separator()
  imgui.Spacing()

  local d_brief = str(B.brief)
  local d_desc  = str(B.desc)
  local d_loc   = str(B.loc)
  local d_tac   = str(B.tac)

  -- Краткое описание
  fieldLabel(tbi('ICON_NOTES') .. ' Краткое описание')
  imgui.PushItemWidth(-1)
  imgui.InputText('##brief', B.brief, 81)
  imgui.PopItemWidth()
  imgui.Spacing()

  -- Полное описание
  fieldLabel(tbi('ICON_WRITING') .. ' Описание ситуации')
  imgui.PushItemWidth(-1)
  imgui.InputTextMultiline('##desc', B.desc, 1025, imgui.ImVec2(-1, 130))
  imgui.PopItemWidth()

  local dlen = #d_desc
  imgui.PushStyleColor(imgui.Col.Text,
    dlen < 10 and imgui.ImVec4(0.95, 0.35, 0.35, 0.90) or imgui.ImVec4(0.30, 0.30, 0.32, 1))
  imgui.Text('Минимальное кол-во символов: 10')
  imgui.PopStyleColor()
  imgui.Spacing()

  -- Два поля в ряд
  local half = (imgui.GetContentRegionAvail().x - 12) / 2
  local pad  = imgui.GetStyle().WindowPadding.x
  fieldLabel(tbi('ICON_LOCATION_FILLED') .. ' Местоположение')
  imgui.SameLine(pad + half + 12)
  fieldLabel(tbi('ICON_RADIO') .. ' ТАК-канал')
  imgui.PushItemWidth(half)
  imgui.InputText('##loc', B.loc, 129)
  imgui.PopItemWidth()
  imgui.SameLine(0, 12)
  imgui.PushItemWidth(-1)
  imgui.InputText('##tac', B.tac, 33)
  imgui.PopItemWidth()
  imgui.Spacing()

  if err_msg then
    errorText(err_msg)
    imgui.Spacing()
  end

  imgui.Separator()
  imgui.Spacing()

  local can_send = #d_brief > 0 and dlen >= 10 and not loading
  if loading then
    loaderDots('Отправка вызова')
  elseif fullBtn(tbi('ICON_SEND') .. ' Отправить вызов', not can_send) then
    loading = true; err_msg = nil
    api('POST', '/api/samp/callout', {
      nick              = nick,
      subdivision_id    = sel_id,
      description       = d_desc,
      brief_description = d_brief,
      location          = #d_loc > 0 and d_loc or nil,
      tac_channel       = #d_tac > 0 and d_tac or nil,
    }, auth, function(data, er)
      loading = false
      if er == 'UNAUTHORIZED' then
        auth = nil; nick = nil; clearFactionCache(); screen = 'token'; os.remove(CFG.cfg_file)
      elseif er then
        err_msg = cleanMsg(er)
      else
        cid = data.callout_id; screen = 'success'
        -- При отправке сразу подтягиваем актуальный список с сервера
        fetchActiveCallouts()
      end
    end)
  end

  imgui.Spacing()
  imgui.End()
end

-- ═══════════════════════════════════════════════════════════
--  ЭКРАН: УСПЕХ
-- ═══════════════════════════════════════════════════════════

local function drawSuccess()
  local sw, sh = getScreenResolution()
  applyWindowPos()
  applyWindowSize('success')
  local flags = imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
  if not imgui.Begin('##ok', visible, flags) then imgui.End(); return end
  trackWindowPos(); trackWindowSize('success')
  drawDecor(); drawCloseBtn(); drawSettingsBtn()

  imgui.Spacing()

  -- Иконка успеха
  do
    local check_str = tbi('ICON_CIRCLE_CHECK_FILLED')
    if check_str ~= '' then
      imgui.PushFont(fnt_ti_xl)
      local w = imgui.GetContentRegionAvail().x
      imgui.SetCursorPosX(imgui.GetCursorPosX() + (w - imgui.CalcTextSize(check_str).x) * 0.5)
      imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.92, 0.92, 0.92, 0.85))
      imgui.Text(check_str)
      imgui.PopStyleColor()
      imgui.PopFont()
    end
  end

  imgui.PushFont(fnt_title)
  shadowCenterText('Вызов отправлен!', 0.60)
  imgui.PopFont()

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()

  imgui.PushFont(fnt_bold)
  imgui.PushStyleColor(imgui.Col.Text, FG)
  centerText('Инцидент #' .. tostring(cid or 0))
  imgui.PopStyleColor()
  imgui.PopFont()

  imgui.Spacing()
  do
    local msg = 'Каллаут уже отправлен. Ожидайте отклика в канале каллаута в Discord.'
    local avail = imgui.GetContentRegionAvail().x
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50, 0.50, 0.53, 1))
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + avail)
    imgui.TextWrapped(msg)
    imgui.PopTextWrapPos()
    imgui.PopStyleColor()
  end
  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()

  -- Авто-таймер закрытия: стартует при показе экрана, прогресс заполняет кнопку
  -- «Закрыть»; по достижении конца окно закрывается само.
  if not is_closing and not success_at then success_at = os.clock() end
  local prog = success_at and math.min(1, (os.clock() - success_at) / SUCCESS_CLOSE_SEC) or 0

  local hw = (imgui.GetContentRegionAvail().x - 8) / 2
  imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.10, 0.10, 0.10, 0.80))
  imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.22, 0.22, 0.22, 1.00))
  if imgui.Button('Ещё вызов', imgui.ImVec2(hw, 36)) then
    screen = 'subdivisions'; sel_id = nil; cid = nil; subs = {}; success_at = nil
  end
  imgui.PopStyleColor(2)

  imgui.SameLine(0, 8)
  -- Кнопка «Закрыть» с встроенным прогресс-баром авто-закрытия.
  -- Подпись содержит назначенную клавишу закрытия: «[Ctrl+F2] Закрыть».
  local close_lbl = 'Закрыть'
  if close_hotkey_vk > 0 then
    close_lbl = '[' .. table.concat(closeHotkeyParts(), '+') .. '] Закрыть'
  end
  do
    local clicked = imgui.InvisibleButton('##close_btn', imgui.ImVec2(hw, 36))
    local hov = imgui.IsItemHovered()
    local mn, mx = imgui.GetItemRectMin(), imgui.GetItemRectMax()
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(mn, mx, c32(0.10, 0.10, 0.10, hov and 1.0 or 0.80), 4, 15)
    if prog > 0 then
      local fx = mn.x + (mx.x - mn.x) * prog
      dl:AddRectFilled(mn, imgui.ImVec2(fx, mx.y), c32(0.92, 0.92, 0.92, 0.16), 4, 15)
    end
    dl:AddRect(mn, mx, c32(0.92, 0.92, 0.92, 0.14), 4, 15, 1)
    local tw, fh = imgui.CalcTextSize(close_lbl).x, imgui.GetFontSize()
    dl:AddText(imgui.ImVec2((mn.x+mx.x)*0.5 - tw*0.5, (mn.y+mx.y)*0.5 - fh*0.5), c32(0.92,0.92,0.92,1), close_lbl)
    if clicked then closeWindow() end
  end

  -- Время вышло — закрываем окно
  if not is_closing and prog >= 1 then closeWindow() end

  imgui.Spacing()
  imgui.End()
end

-- ═══════════════════════════════════════════════════════════
--  ЭКРАН: ПОЛНАЯ КАРТОЧКА КАЛЛАУТА
-- ═══════════════════════════════════════════════════════════

-- Строка «подпись: значение» в две колонки
local function cardKV(label, value)
  if not value or value == '' then return end
  fieldLabel(label)
  imgui.PushStyleColor(imgui.Col.Text, FG)
  imgui.PushTextWrapPos(imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x)
  imgui.TextWrapped(value)
  imgui.PopTextWrapPos()
  imgui.PopStyleColor()
  imgui.Spacing()
end

local function drawCalloutCard()
  applyWindowPos()
  applyWindowSize('callout_card')
  -- NoScrollbar: вертикаль прокручивается во вложенном теле (##ccbody), а длинные
  -- необорачиваемые строки (имя/время) не должны плодить горизонтальный скролл.
  local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
  if not imgui.Begin('##ccard', visible, flags) then imgui.End(); return end
  trackWindowPos(); trackWindowSize('callout_card')
  drawDecor(); drawCloseBtn(); drawSettingsBtn()

  local c = sel_callout
  if not c then screen = 'subdivisions'; imgui.End(); return end
  local d = c.detail  -- ответ сервера (может быть nil до первого опроса)

  -- ── Шапка: Назад + заголовок ────────────────────────────────
  imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.08, 0.08, 0.08, 0.60))
  imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.20, 0.20, 0.20, 0.80))
  if imgui.SmallButton(tbi('ICON_ARROW_BACK_UP') .. ' Назад') then screen = 'subdivisions' end
  imgui.PopStyleColor(2)
  imgui.SameLine(0, 12)
  imgui.PushFont(fnt_bold)
  imgui.Text('Каллаут #' .. tostring(c.id))
  imgui.PopFont()
  imgui.Separator()
  imgui.Spacing()

  -- ── Блок фракции: лого + название + бейдж статуса ───────────
  do
    local dl   = imgui.GetWindowDrawList()
    local wp   = imgui.GetWindowPos()
    local cp   = imgui.GetCursorPos()
    local lsz  = 56
    local lx   = wp.x + cp.x
    local ly   = wp.y + cp.y
    local tex  = c.faction_logo_url and fact_textures[c.faction_logo_url]
    if tex then
      dl:AddImageRounded(tex, imgui.ImVec2(lx, ly), imgui.ImVec2(lx + lsz, ly + lsz),
        imgui.ImVec2(0, 0), imgui.ImVec2(1, 1), c32(1, 1, 1, 1), 10, 15)
    else
      dl:AddRectFilled(imgui.ImVec2(lx, ly), imgui.ImVec2(lx + lsz, ly + lsz), c32(0.18, 0.18, 0.20, 1), 10, 15)
      imgui.PushFont(fnt_big)
      local ab = (c.faction_name or '?'):sub(1, 1)
      local aw, afh = imgui.CalcTextSize(ab).x, imgui.GetFontSize()
      dl:AddText(imgui.ImVec2(lx + lsz * 0.5 - aw * 0.5, ly + lsz * 0.5 - afh * 0.5), c32(0.55, 0.55, 0.58, 1), ab)
      imgui.PopFont()
    end

    imgui.Dummy(imgui.ImVec2(lsz, lsz))
    imgui.SameLine(0, 14)
    imgui.BeginGroup()
    imgui.PushFont(fnt_bold)
    imgui.PushStyleColor(imgui.Col.Text, FG)
    imgui.Text((d and d.subdivision_name) or c.faction_name or '?')
    imgui.PopStyleColor()
    imgui.PopFont()

    -- Бейдж статуса
    local meta = statusMeta(c.status)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(meta.r, meta.g, meta.b, 1))
    imgui.Text((tbi('ICON_POINT_FILLED') ~= '' and (tbi('ICON_POINT_FILLED') .. ' ') or '') .. meta.label)
    imgui.PopStyleColor()

    -- Создан N назад (живой счётчик с секундами) + Закрыт N назад, если закрыт.
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.50, 0.50, 0.53, 1))
    imgui.Text('Создан ' .. fmtAgo(os.time() - c.created_at))
    local cl, cr = isoToEpoch(d and d.closed_at), isoToEpoch(d and d.created_at)
    if cl and cr then
      -- closed−created — TZ-безопасная «длительность жизни»; вычитаем из «прошло с создания»
      imgui.Text('Закрыт ' .. fmtAgo((os.time() - c.created_at) - (cl - cr)))
    end
    imgui.PopStyleColor()
    imgui.EndGroup()
  end

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()

  -- ── Прокручиваемое тело карточки ────────────────────────────
  local foot_h = 54   -- separator + spacing + кнопка(34) + spacing
  local body_h = math.max(80, imgui.GetContentRegionAvail().y - foot_h)
  imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
  if imgui.BeginChild('##ccbody', imgui.ImVec2(-1, body_h), false) then
    -- Краткое — только если оно реально есть (иначе дублировало бы «Описание»)
    cardKV(tbi('ICON_NOTES') .. ' Краткое описание', d and d.brief_description)
    cardKV(tbi('ICON_WRITING') .. ' Описание ситуации', c.description or (d and d.description))
    cardKV(tbi('ICON_LOCATION_FILLED') .. ' Местоположение', c.location)
    cardKV(tbi('ICON_RADIO') .. ' ТАК-канал', c.tac)

    -- Отклики подразделений (принявшие)
    if d and d.responses and #d.responses > 0 then
      sectionLabel('ОТКЛИКНУЛИСЬ (' .. #d.responses .. ')')
      imgui.Spacing()
      for _, r in ipairs(d.responses) do
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40, 0.70, 0.45, 1))
        imgui.Text((tbi('ICON_CHECK') ~= '' and (tbi('ICON_CHECK') .. ' ') or '· ') .. tostring(r.name or '?'))
        imgui.PopStyleColor()
      end
      imgui.Spacing()
    end

    -- Причина отклонения
    if d and d.declined then
      sectionLabel('ОТКЛОНЕНО')
      imgui.Spacing()
      if d.declined.by_name then
        fieldLabel('Кем')
        imgui.PushStyleColor(imgui.Col.Text, FG)
        imgui.Text(tostring(d.declined.by_name))
        imgui.PopStyleColor()
      end
      if d.declined.reason and d.declined.reason ~= '' then
        fieldLabel('Причина')
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.92, 0.55, 0.55, 1))
        imgui.PushTextWrapPos(imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x)
        imgui.TextWrapped(tostring(d.declined.reason))
        imgui.PopTextWrapPos()
        imgui.PopStyleColor()
      end
      imgui.Spacing()
    end

    -- Причина закрытия
    if d and d.status == 'closed' and d.closed_reason and d.closed_reason ~= '' then
      cardKV(tbi('ICON_LOCK') .. ' Закрыт', tostring(d.closed_reason))
    end
  end
  imgui.EndChild()
  imgui.PopStyleColor()

  -- ── Низ: обновить статус с сервера ──────────────────────────
  imgui.Separator()
  imgui.Spacing()
  imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.10, 0.10, 0.10, 0.80))
  imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.22, 0.22, 0.22, 1.00))
  local refresh_lbl = ac_fetching and 'Обновление...' or 'Обновить'
  if imgui.Button(refresh_lbl, imgui.ImVec2(imgui.GetContentRegionAvail().x, 34)) and not ac_fetching then
    fetchActiveCallouts()
  end
  imgui.PopStyleColor(2)

  imgui.Spacing()
  imgui.End()
end

-- ═══════════════════════════════════════════════════════════
--  ЭКРАН: НАСТРОЙКИ
-- ═══════════════════════════════════════════════════════════

-- ─── Карточка аккаунта: аватар + ник + статус ────────────────
local function drawAccountCard()
  local dl    = imgui.GetWindowDrawList()
  local wp    = imgui.GetWindowPos()
  local cp    = imgui.GetCursorPos()
  local avail = imgui.GetContentRegionAvail().x
  local ch    = 56
  local x1, y1 = wp.x + cp.x, wp.y + cp.y
  local x2, y2 = x1 + avail, y1 + ch

  dl:AddRectFilled(imgui.ImVec2(x1,y1), imgui.ImVec2(x2,y2), c32(0.92,0.92,0.92,0.04), 8, 15)
  dl:AddRect(imgui.ImVec2(x1,y1), imgui.ImVec2(x2,y2), c32(0.92,0.92,0.92,0.10), 8, 15, 1)

  -- Аватар
  local av_sz = 36
  local av_cx = x1 + 14 + av_sz*0.5
  local av_cy = y1 + ch*0.5
  local av_r  = av_sz*0.5
  local av_tex = type(user_avatar_url) == 'string' and fact_textures[user_avatar_url]
  if av_tex then
    dl:AddImageRounded(av_tex,
      imgui.ImVec2(av_cx-av_r, av_cy-av_r), imgui.ImVec2(av_cx+av_r, av_cy+av_r),
      imgui.ImVec2(0,0), imgui.ImVec2(1,1), c32(1,1,1,0.95), av_r, 15)
  else
    dl:AddCircleFilled(imgui.ImVec2(av_cx,av_cy), av_r, c32(0.18,0.18,0.20,1), 32)
    dl:AddCircle(imgui.ImVec2(av_cx,av_cy), av_r, c32(0.92,0.92,0.92,0.12), 32, 1)
    imgui.PushFont(fnt_big)
    local letter = (nick or '?'):sub(1,1):upper()
    local lw, lfh = imgui.CalcTextSize(letter).x, imgui.GetFontSize()
    dl:AddText(imgui.ImVec2(av_cx-lw*0.5, av_cy-lfh*0.5), c32(0.55,0.55,0.58,1), letter)
    imgui.PopFont()
  end

  -- Ник + статус привязки
  local tx = x1 + 14 + av_sz + 12
  imgui.PushFont(fnt_bold)
  local nfh = imgui.GetFontSize()
  dl:AddText(imgui.ImVec2(tx, av_cy - nfh - 1), c32(0.92,0.92,0.92,0.95), nick or '?')
  imgui.PopFont()
  local check  = (ok_ti and tbi('ICON_CIRCLE_CHECK_FILLED')) or ''
  local status = (check ~= '' and (check..' ') or '') .. 'Привязан'
  dl:AddText(imgui.ImVec2(tx, av_cy + 3), c32(0.40,0.62,0.42,1), status)

  imgui.Dummy(imgui.ImVec2(avail, ch))
end

-- ─── Строка настройки горячей клавиши (компактная: подпись слева, контрол справа) ─
-- mode: 'open' | 'close' — какие глобалы читать/писать и какой режим захвата
local function drawHotkeyRow(label, mode)
  local vk        = (mode == 'close') and close_hotkey_vk or hotkey_vk
  local parts     = (mode == 'close') and closeHotkeyParts() or hotkeyParts()
  local capturing = (waiting_key == mode)

  local dl    = imgui.GetWindowDrawList()
  local wp    = imgui.GetWindowPos()
  local cp    = imgui.GetCursorPos()
  local avail = imgui.GetContentRegionAvail().x
  local rowh  = 34
  local fh    = imgui.GetFontSize()
  local rx, ry = wp.x + cp.x, wp.y + cp.y

  -- Левая подпись (по центру по вертикали)
  dl:AddText(imgui.ImVec2(rx, ry + (rowh - fh) * 0.5), c32(0.72, 0.72, 0.75, 1), label)

  -- Справа: [ бокс сочетания ] [ × сброс ]
  local show_reset = (vk > 0 and not capturing)
  local gap     = 6
  local reset_w = show_reset and rowh or 0
  local box_w   = 140
  local box_x2  = rx + avail - (reset_w > 0 and (reset_w + gap) or 0)
  local box_x1  = box_x2 - box_w
  local box_y1, box_y2 = ry, ry + rowh

  local box_hov = imgui.IsMouseHoveringRect(imgui.ImVec2(box_x1,box_y1), imgui.ImVec2(box_x2,box_y2), false)
  if capturing then
    local pulse = (math.sin(os.clock() * 5) + 1) * 0.5
    dl:AddRectFilled(imgui.ImVec2(box_x1,box_y1), imgui.ImVec2(box_x2,box_y2), c32(0.92,0.92,0.92, 0.04 + pulse*0.05), 6, 15)
    dl:AddRect(imgui.ImVec2(box_x1,box_y1), imgui.ImVec2(box_x2,box_y2), c32(0.92,0.92,0.92, 0.18 + pulse*0.24), 6, 15, 1)
    local held = modNames(currentMods())
    held[#held+1] = '…'
    drawHotkeyChord(dl, box_x1, box_y1, box_w, rowh, held, 0.55 + pulse*0.45)
  else
    dl:AddRectFilled(imgui.ImVec2(box_x1,box_y1), imgui.ImVec2(box_x2,box_y2), c32(0.92,0.92,0.92, box_hov and 0.10 or 0.05), 6, 15)
    dl:AddRect(imgui.ImVec2(box_x1,box_y1), imgui.ImVec2(box_x2,box_y2), c32(0.92,0.92,0.92, box_hov and 0.22 or 0.12), 6, 15, 1)
    if vk > 0 then
      drawHotkeyChord(dl, box_x1, box_y1, box_w, rowh, parts, 1.0)
    else
      local none = 'Назначить'
      local tw = imgui.CalcTextSize(none).x
      dl:AddText(imgui.ImVec2(box_x1+(box_w-tw)*0.5, box_y1+(rowh-fh)*0.5), c32(0.55,0.55,0.58, box_hov and 1.0 or 0.7), none)
    end
  end

  -- Клик по боксу: старт захвата (или отмена, если уже ждём)
  if box_hov and imgui.IsMouseClicked(0) then
    if capturing then waiting_key = false else waiting_key = mode end
  end

  -- Кнопка сброса (×)
  if show_reset then
    local rsx1 = box_x2 + gap
    local rsx2 = rsx1 + reset_w
    local rs_hov = imgui.IsMouseHoveringRect(imgui.ImVec2(rsx1,box_y1), imgui.ImVec2(rsx2,box_y2), false)
    dl:AddRectFilled(imgui.ImVec2(rsx1,box_y1), imgui.ImVec2(rsx2,box_y2), c32(0.92,0.92,0.92, rs_hov and 0.10 or 0.05), 6, 15)
    dl:AddRect(imgui.ImVec2(rsx1,box_y1), imgui.ImVec2(rsx2,box_y2), c32(0.92,0.92,0.92, rs_hov and 0.20 or 0.10), 6, 15, 1)
    local xg = (ok_ti and tbi('ICON_X') ~= '' and tbi('ICON_X')) or 'x'
    local tw = imgui.CalcTextSize(xg).x
    dl:AddText(imgui.ImVec2(rsx1+(reset_w-tw)*0.5, box_y1+(rowh-fh)*0.5), c32(0.85,0.45,0.45, rs_hov and 1.0 or 0.65), xg)
    if rs_hov and imgui.IsMouseClicked(0) then
      if mode == 'close' then close_hotkey_vk = 0; close_hotkey_mods = {}
      else hotkey_vk = 0; hotkey_mods = {} end
      saveConfig()
    end
  end

  imgui.Dummy(imgui.ImVec2(avail, rowh))
end

local settings_need_h  -- измеренная в прошлом кадре высота под весь контент + футер

local function drawSettings()
  local sw, sh = getScreenResolution()
  applyWindowPos()
  -- Минимум высоты = реально измеренная высота контента (со след. кадра), чтобы окно
  -- нельзя было сузить так, что кнопки «съедаются». Нативный скролл не используем.
  applyWindowSize('settings', settings_need_h)
  local flags = imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
             + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
  if not imgui.Begin('##cfg', visible, flags) then imgui.End(); return end
  trackWindowPos(); trackWindowSize('settings')
  drawGrid(); drawDecor(); drawCloseBtn()

  -- Шапка
  imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.08, 0.08, 0.08, 0.60))
  imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.18, 0.18, 0.18, 0.80))
  if imgui.SmallButton('Назад') then
    waiting_key = false; screen = prev_screen
  end
  imgui.PopStyleColor(2)
  imgui.SameLine(0, 12)
  imgui.PushFont(fnt_bold)
  imgui.Text('Настройки')
  imgui.PopFont()
  imgui.Separator()
  imgui.Spacing()

  -- Карточка аккаунта
  drawAccountCard()
  imgui.Spacing()
  imgui.Spacing()

  -- Горячие клавиши (две настраиваемые привязки)
  sectionLabel('ГОРЯЧИЕ КЛАВИШИ')
  imgui.Spacing()
  drawHotkeyRow('Открыть меню', 'open')
  imgui.Spacing()
  drawHotkeyRow('Закрыть после успеха', 'close')

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()

  -- Громкость оповещений (+ кнопка прослушать)
  sectionLabel('ЗВУК')
  imgui.Spacing()
  imgui.AlignTextToFramePadding()
  local vicon = (tbi('ICON_VOLUME') ~= '' and (tbi('ICON_VOLUME') .. ' ')) or ''
  imgui.Text(vicon .. 'Громкость оповещений')

  local test_w = 36
  local sl_w   = imgui.GetContentRegionAvail().x - test_w - 8
  imgui.PushStyleColor(imgui.Col.FrameBg,        imgui.ImVec4(0.10, 0.10, 0.10, 0.70))
  imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0.16, 0.16, 0.16, 0.85))
  imgui.PushStyleColor(imgui.Col.SliderGrab,        imgui.ImVec4(0.35, 0.78, 0.42, 0.90))
  imgui.PushStyleColor(imgui.Col.SliderGrabActive,  imgui.ImVec4(0.45, 0.88, 0.52, 1.00))
  imgui.PushItemWidth(sl_w)
  if imgui.SliderInt('##notif_vol', vol_ref, 0, 100, '%d%%') then
    notify_vol = math.max(0, math.min(1, vol_ref[0] / 100))
    applyNotifyVolume()
  end
  if imgui.IsItemDeactivatedAfterEdit() then saveConfig() end
  imgui.PopItemWidth()
  imgui.PopStyleColor(4)

  imgui.SameLine(0, 8)
  imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.10, 0.10, 0.10, 0.80))
  imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.22, 0.22, 0.22, 1.00))
  local picon = (tbi('ICON_PLAYER_PLAY_FILLED') ~= '' and tbi('ICON_PLAYER_PLAY_FILLED'))
             or (tbi('ICON_VOLUME') ~= '' and tbi('ICON_VOLUME')) or '>'
  if imgui.Button(picon .. '##voltest', imgui.ImVec2(test_w, 0)) then playNotifySound() end
  imgui.PopStyleColor(2)

  -- Баннер обновления (если доступна новая версия)
  if upd.available then
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    if fullBtn('Обновить до ' .. tostring(upd.latest or '?'), false, 'upd_soft') then
      screen = 'update'
    end
  end

  -- ── Ряд «Discord + Выйти», прижатый к низу окна ──────────────
  -- foot_h — высота самого ряда (separator + spacing + кнопки 34 + запас).
  local foot_h = 48
  local content_bottom = imgui.GetCursorPosY()
  -- Запоминаем нужную высоту окна = контент + футер (+низ. паддинг) для минимума.
  settings_need_h = content_bottom + foot_h + 16
  -- Прижать ряд к низу, если место есть; иначе оставить сразу под контентом.
  local fy = content_bottom + imgui.GetContentRegionAvail().y - foot_h
  if fy > content_bottom then imgui.SetCursorPosY(fy) end
  imgui.Separator()
  imgui.Spacing()
  local hw = (imgui.GetContentRegionAvail().x - 8) / 2
  imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.10, 0.10, 0.10, 0.80))
  imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.22, 0.22, 0.22, 1.00))
  local dc_icon = (ok_ti and tbi('ICON_SHARE_2') ~= '' and (tbi('ICON_SHARE_2') .. ' ')) or ''
  if imgui.Button(dc_icon .. 'Discord', imgui.ImVec2(hw, 34)) then
    os.execute('start "" "' .. CFG.discord_url .. '"')
  end
  imgui.PopStyleColor(2)

  imgui.SameLine(0, 8)
  imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.30, 0.10, 0.10, 0.70))
  imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.55, 0.12, 0.12, 0.90))
  if imgui.Button('Выйти', imgui.ImVec2(hw, 34)) then
    auth = nil; nick = nil; clearFactionCache()
    screen = 'token'; show_auth = false; err_msg = nil; waiting_key = false
    os.remove(CFG.cfg_file)
  end
  imgui.PopStyleColor(2)

  imgui.Spacing()
  imgui.Spacing()
  imgui.End()
end

-- ═══════════════════════════════════════════════════════════
--  ЭКРАН: ОБНОВЛЕНИЕ
-- ═══════════════════════════════════════════════════════════

local function drawUpdate()
  applyWindowPos()
  applyWindowSize('update')
  local flags = imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
  if not imgui.Begin('##upd', visible, flags) then imgui.End(); return end
  trackWindowPos(); trackWindowSize('update')
  drawGrid(); drawDecor(); drawCloseBtn()

  imgui.Spacing()
  imgui.PushFont(fnt_title)
  shadowCenterText(upd.required and 'Версия устарела' or 'Доступно обновление', 0.60)
  imgui.PopFont()

  imgui.Spacing()
  imgui.PushFont(fnt_bold)
  imgui.PushStyleColor(imgui.Col.Text, FG)
  centerText(VERSION .. '  ->  ' .. tostring(upd.latest or '?'))
  imgui.PopStyleColor()
  imgui.PopFont()

  imgui.Spacing()
  if upd.required then
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.95, 0.45, 0.45, 1))
    local m = 'Эта версия больше не поддерживается сервером. Обновитесь, чтобы продолжить пользоваться.'
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x)
    imgui.TextWrapped(m)
    imgui.PopTextWrapPos()
    imgui.PopStyleColor()
    imgui.Spacing()
  end
  if upd.changelog then
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.55, 0.55, 0.58, 1))
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x)
    imgui.TextWrapped('Что нового: ' .. upd.changelog)
    imgui.PopTextWrapPos()
    imgui.PopStyleColor()
    imgui.Spacing()
  end

  imgui.Separator()
  imgui.Spacing()

  if upd.busy then
    imgui.PushStyleColor(imgui.Col.Text, FG)
    centerText(upd.status or 'Обновление...')
    imgui.PopStyleColor()
  else
    if fullBtn('Обновить сейчас', false, 'do_update') then doAutoUpdate() end
    imgui.Spacing()
    imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.10, 0.10, 0.10, 0.80))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.22, 0.22, 0.22, 1.00))
    if imgui.Button('Открыть GitHub (вручную)', imgui.ImVec2(imgui.GetContentRegionAvail().x, 32)) then
      os.execute('start "" "' .. CFG.repo_url .. '"')
    end
    imgui.PopStyleColor(2)
  end

  imgui.Spacing()
  imgui.End()
end

-- ═══════════════════════════════════════════════════════════
--  РЕНДЕР
-- ═══════════════════════════════════════════════════════════

imgui.OnFrame(
  -- Рендерим, когда открыто основное окно ИЛИ есть активные тосты-оповещения
  function() return visible[0] or is_closing or #toasts > 0 end,
  function(self)
    local main_open = visible[0] or is_closing
    -- Курсор показываем только при открытом меню; при одних тостах — пассивный
    -- оверлей (HideCursor=true), чтобы не перехватывать управление игрой.
    self.HideCursor = not main_open
    updateAnim()

    -- Создаём текстуры из очереди (только в render thread — безопасно для D3D)
    if #fact_tex_queue > 0 then
      local item = table.remove(fact_tex_queue, 1)
      if item and not fact_textures[item.url] then
        local tex = imgui.CreateTextureFromFile(item.path)
        if tex then fact_textures[item.url] = tex end
      end
    end

    -- Тосты — поверх игры всегда (в т.ч. при закрытом меню), своя прозрачность
    drawToasts()

    -- Основное окно — только когда открыто/закрывается
    if main_open then
      imgui.PushStyleVarFloat(0, anim_alpha)  -- 0 = ImGuiStyleVar_Alpha
      imgui.PushFont(fnt_reg)  -- Inter-Regular как дефолт для всех виджетов
      applyTheme()
      -- Обязательное обновление перекрывает любой экран
      if upd.required then screen = 'update' end
      if     screen == 'token'        then drawToken()
      elseif screen == 'subdivisions' then drawSubdivisions()
      elseif screen == 'callout'      then drawCallout()
      elseif screen == 'callout_card' then drawCalloutCard()
      elseif screen == 'success'      then drawSuccess()
      elseif screen == 'settings'     then drawSettings()
      elseif screen == 'update'       then drawUpdate()
      end
      imgui.PopFont()
      imgui.PopStyleVar()
    end
  end
)

-- ═══════════════════════════════════════════════════════════
--  ЗАПУСК
-- ═══════════════════════════════════════════════════════════

function main()
  repeat wait(100) until isSampAvailable()
  wait(500)

  local ok, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
  if ok then local_nick = sampGetPlayerNickname(pid) end

  loadConfig()
  if auth then
    fetchUserAvatar()       -- fetchUserAvatar определена к этому моменту
    fetchActiveCallouts()   -- базлайн статусов + фоновый watch с самого старта
  end

  for _, cmd in ipairs(CFG.commands) do
    sampRegisterChatCommand(cmd, function(arg)
      -- «/callout update» — запустить автообновление
      if arg and arg:lower():match('^%s*update%s*$') then
        doAutoUpdate()
        return
      end
      if visible[0] and not is_closing then
        closeWindow()
      else
        openWindow()
      end
    end)
  end

  sampAddChatMessage(u8:decode('{DC143C}[SAES CALLOUT]{FFFFFF} Система загружена. Команды: /callout или /911.'), -1)
  if not doesFileExist(CFG.cfg_file) then
    sampAddChatMessage(u8:decode('{DC143C}[SAES CALLOUT]{FFFFFF} Вы можете настроить горячую клавишу открытия меню в настройках.'), -1)
  end

  -- Проверка обновлений (асинхронно, не блокирует)
  checkForUpdate()

  while true do
    wait(0)
    -- Один HTTP-запрос за кадр (localhost <1мс, заметных фризов нет)
    processNextHttp()

    -- Автообновление списка каллаутов:
    --  • меню открыто  → 10с если есть каллауты, иначе 30с;
    --  • меню закрыто  → 12с, ПОКА есть что отслеживать (pending/declined) — чтобы
    --    поймать переход в «принят» и показать оповещение даже при свёрнутом окне.
    if auth then
      local interval
      if visible[0] then
        interval = (#active_callouts > 0) and AC_INTERVAL_ACTIVE or AC_INTERVAL
      elseif hasWatchableCallouts() then
        interval = AC_INTERVAL_BG
      end
      if interval and (os.clock() - ac_fetch_at) > interval then
        fetchActiveCallouts()
      end
    end

    -- Сохранение размера окна после ресайза (дебаунс 1с, чтобы не писать каждый кадр)
    if win_size_dirty and (os.clock() - win_size_saved_at) > 1.0 then
      saveConfig()
      win_size_dirty = false
      win_size_saved_at = os.clock()
    end
    -- Финализация закрытия: когда alpha дошла до нуля
    if is_closing and anim_alpha <= 0.01 then
      visible[0] = false
      is_closing  = false
      anim_alpha  = 0.0
    end
    -- ESC закрывает с анимацией
    if visible[0] and not is_closing and wasKeyPressed(0x1B) then
      if waiting_key then waiting_key = false
      else closeWindow() end
    end

    -- Ожидание нажатия клавиши/сочетания в настройках (waiting_key = 'open' | 'close')
    local captured_this_frame = false
    if waiting_key then
      for vk, _ in pairs(VK_NAMES) do
        if wasKeyPressed(vk) then
          local mods = currentMods()  -- зажатые в момент нажатия модификаторы
          if waiting_key == 'close' then
            close_hotkey_vk = vk; close_hotkey_mods = mods
          else
            hotkey_vk = vk; hotkey_mods = mods
          end
          waiting_key = false; saveConfig(); captured_this_frame = true; break
        end
      end
    end

    -- Основная горячая клавиша — открыть/закрыть меню.
    -- captured_this_frame: не срабатываем в том же кадре, где клавиша только что
    -- назначена (иначе только что нажатая клавиша сразу же закрыла бы меню).
    if not waiting_key and not captured_this_frame and hotkeyTriggered() then
      if visible[0] and not is_closing then closeWindow()
      else openWindow() end
    end

    -- Горячая клавиша закрытия — работает на экране успеха после отправки каллаута
    if not waiting_key and not captured_this_frame and visible[0] and not is_closing
       and screen == 'success' and closeHotkeyTriggered() then
      closeWindow()
    end
  end
end

function onScriptTerminate(s, _q)
  if s == script.this then visible[0] = false end
end
