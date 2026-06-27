#!/usr/bin/env python3
"""
Разбивает src/saes_callout.lua на две части для пайплайна обфускации:

  dist/saes_callout.plain.lua  — лицензия + метаданные script_* + effil-воркер
                                 (package.preload). НЕ обфусцируется.
  dist/saes_callout.core.lua   — всё остальное тело скрипта. Уходит в Prometheus.

Граница задаётся маркерами в исходнике:
    --@PLAIN-BEGIN ... --@PLAIN-END   → плейн-тело (между маркерами);
    всё ДО --@PLAIN-BEGIN (лицензия)  → тоже в плейн (идёт первым в дистрибутиве);
    всё ПОСЛЕ --@PLAIN-END            → core (под обфускацию).

Линковка плейн↔core — только через require-строку ('saes_callout.httpworker'):
общих локалов через границу быть НЕ должно (обфускация переименовала бы их в core,
но не в плейне). split.py этого не проверяет — следи руками.

Также пишет dist/saes_callout.test.lua (plain + core) для синтакс-проверки ИСХОДНИКА
до обфускации, и сверяет версию в script_version(...) с `local VERSION`.

Запуск:  python build/split.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "saes_callout.lua")
OUT_DIR = os.path.join(ROOT, "dist")

BEGIN = "--@PLAIN-BEGIN"
END = "--@PLAIN-END"


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        s = f.read()
    if s and s[0] == "﻿":
        s = s[1:]
    return s


def strip_lua_comments(src):
    """Удаляет Lua-комментарии (-- ... и --[[ ]]), НЕ трогая строковые литералы
    ('...', "...", [[...]]). Нужно для плейн-тела дистрибутива: открытая часть —
    сугубо код. Воркер содержит строки ('socket.http' и пр.) — их не трогаем."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"' or c == "'":  # короткая строка
            q = c
            out.append(c); i += 1
            while i < n:
                ch = src[i]; out.append(ch)
                if ch == "\\" and i + 1 < n:
                    out.append(src[i + 1]); i += 2; continue
                i += 1
                if ch == q:
                    break
            continue
        if c == "[":  # длинная строка [[ ]] / [=[ ]=]
            j = i + 1; eq = 0
            while j < n and src[j] == "=":
                eq += 1; j += 1
            if j < n and src[j] == "[":
                close = "]" + "=" * eq + "]"
                end = src.find(close, j + 1)
                end = n if end == -1 else end + len(close)
                out.append(src[i:end]); i = end
                continue
            out.append(c); i += 1; continue
        if c == "-" and i + 1 < n and src[i + 1] == "-":  # комментарий
            k = i + 2
            if k < n and src[k] == "[":
                m = k + 1; eq = 0
                while m < n and src[m] == "=":
                    eq += 1; m += 1
                if m < n and src[m] == "[":  # блочный --[[ ]]
                    close = "]" + "=" * eq + "]"
                    end = src.find(close, m + 1)
                    i = n if end == -1 else end + len(close)
                    continue
            end = src.find("\n", i)  # строчный -- до конца строки
            i = n if end == -1 else end
            continue
        out.append(c); i += 1
    return "".join(out)


def tidy(src):
    """Срез комментариев + хвостовых пробелов + схлопывание пустых строк."""
    lines = [ln.rstrip() for ln in strip_lua_comments(src).splitlines()]
    out, blank = [], False
    for ln in lines:
        if ln == "":
            if blank:
                continue
            blank = True
        else:
            blank = False
        out.append(ln)
    return "\n".join(out).strip("\n")


def main():
    src = read(SRC)
    lines = src.splitlines()

    bi = ei = None
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith(BEGIN):
            bi = i
        elif ln.lstrip().startswith(END):
            ei = i
            break
    if bi is None or ei is None or ei < bi:
        print("split.py: не найдены маркеры %s / %s в src" % (BEGIN, END))
        return 1

    # plain = лицензия (до BEGIN, ДОСЛОВНО) + тело между маркерами БЕЗ комментариев.
    # Открытая необфусцированная часть — сугубо код; оставляем только лицензионную шапку.
    license_txt = "\n".join(lines[:bi]).rstrip("\n")
    body_txt = tidy("\n".join(lines[bi + 1:ei]))
    core_lines = lines[ei + 1:]

    plain_txt = license_txt + "\n\n" + body_txt + "\n"
    core_body = "\n".join(core_lines).strip("\n")
    # Оборачиваем core в IIFE: его top-level локалы (их ~200, у предела Lua) уезжают в
    # область функции, а добавки обфускации (массив констант + дешифратор) остаются в
    # главном чанке — иначе "main function has more than 200 local variables".
    # main/onScriptTerminate объявлены глобально (function name()) → видны снаружи.
    core_txt = "do return (function()\n" + core_body + "\nend)() end\n"

    # Сверка версий: script_version("X") в плейне == local VERSION = "Y" в core.
    m_sv = re.search(r'script_version\s*\(\s*["\']([^"\']+)["\']', plain_txt)
    m_ver = re.search(r'local\s+VERSION\s*=\s*["\']([^"\']+)["\']', core_txt)
    if not m_sv:
        print("split.py: не нашёл script_version(\"...\") в плейн-части")
        return 1
    if not m_ver:
        print("split.py: не нашёл `local VERSION = \"...\"` в core")
        return 1
    if m_sv.group(1) != m_ver.group(1):
        print("split.py: версии расходятся: script_version=%s, VERSION=%s"
              % (m_sv.group(1), m_ver.group(1)))
        return 1

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "saes_callout.plain.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(plain_txt)
    with open(os.path.join(OUT_DIR, "saes_callout.core.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(core_txt)
    with open(os.path.join(OUT_DIR, "saes_callout.test.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(plain_txt + "\n" + core_txt)

    print("split.py: версия %s | plain %d стр, core %d стр"
          % (m_ver.group(1), plain_txt.count("\n"), len(core_lines)))
    print("dist/saes_callout.plain.lua, dist/saes_callout.core.lua, dist/saes_callout.test.lua")
    return 0


if __name__ == "__main__":
    sys.exit(main())
