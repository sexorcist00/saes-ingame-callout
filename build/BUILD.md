# Сборка и релиз SAES Callout

Один репозиторий, обфускация на месте.

## Раскладка

```
src/saes_callout.lua          ← ПЛЕЙН source of truth. Здесь правим. Здесь git-история.
build/                        ← пайплайн сборки (этот каталог)
  build.ps1                   ← главный скрипт
  split.py                    ← делит src на plain | core по маркерам
  assemble.py                 ← склеивает plain + обфусцированный core
  prometheus_config.lua       ← конфиг обфускатора (как в objmapper)
  Prometheus/                 ← сам обфускатор (копия из objmapper)
moonloader/saes_callout.lua   ← ОБФ артефакт. Коммитится в main, его тянет автообновление.
moonloader/lib, resource      ← либы и ресурсы (не трогаются сборкой)
version.json                  ← latest / min_supported / changelog / url (→ обф .lua в raw)
```

`src/` НЕ раздаётся и НЕ читается игрой. Для теста в игре копируем именно `src/saes_callout.lua`
(плоский, грузится как обычный скрипт), правим там, `Ctrl+R`.

## Что плейн, что обфусцируется

Граница в `src/saes_callout.lua` — маркеры `--@PLAIN-BEGIN` / `--@PLAIN-END`. В плейн уходят:

- **метаданные** `script_name/author/version` (литералами) — апдейтер валидирует скачанный
  файл по подстроке `SAES Callout System`, шифрование её бы убило;
- **effil-воркер** `package.preload['saes_callout.httpworker']` — чистая функция без апвелью,
  её effil переносит в OS-поток через `string.dump`. Обфускация добавила бы апвелью на
  дешифратор строк → падение в чужом потоке (та же причина, что у `httpworker` в objmapper).

Линковка плейн↔core — ТОЛЬКО через require-строку `'saes_callout.httpworker'` (переживает
шифрование как обычная строка). Общих локалов через границу быть не должно.

Весь остальной код (core) Prometheus шифрует: строки, пул констант, числа-в-выражения,
плюс минифицирует имена ЛОКАЛОВ. Глобалы (`main`, `onScriptTerminate` и т.п.) не трогает —
поэтому точки входа MoonLoader переживают сборку (проверяется гардом в build.ps1).
Core при сборке оборачивается в IIFE
(`do return (function() ... end)() end`), чтобы его ~200 top-level локалов ушли в область
функции, а добавки обфускатора остались в главном чанке — иначе Lua падает на
«main function has more than 200 local variables». `main`/`onScriptTerminate` объявлены
глобально, поэтому видны снаружи IIFE.

> ⚠ Плоский `src/` у самого предела Lua (200 локалов в главном чанке). Новые top-level
> `local` в core добавляй с оглядкой: dev-копия (без IIFE) может перестать грузиться.
> Сборка от этого защищена (IIFE), но dev-тест — нет.

## Выпуск новой версии

1. Поднять версию в ДВУХ местах `src/saes_callout.lua` (split.py сверяет, что совпадают):
   - `script_version("X")` в плейн-блоке;
   - `local VERSION = "X"` в core.
2. Обновить `version.json`: `latest`, при необходимости `min_supported`, `changelog`.
3. Собрать: `powershell -ExecutionPolicy Bypass -File build/build.ps1`.
   Результат — обновлённый `moonloader/saes_callout.lua` (обф) + проверка синтаксиса
   исходника и финала, гарды на плейн-маркер и тело воркера.
4. Закоммитить `src/`, `moonloader/saes_callout.lua`, `version.json` в `main`.
   Автообновление возьмёт `version.json` и `saes_callout.lua` из raw.githubusercontent.

`lib/` и `resource/` синхронизируются отдельно по `moonloader/resource/manifest.json`
(см. `syncResources` в коде) — меняешь ресурсы, обнови манифест.

## GPL

Раздаётся обфусцированный файл, но source (`src/`) лежит в этом же публичном репо —
требование GPL-3.0 о доступности исходника выполнено.
