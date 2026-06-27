#!/usr/bin/env python3
"""
Финальная сборка раздаваемого файла:
  dist/saes_callout.plain.lua  +  dist/saes_callout.core.obf.lua  ->  moonloader/saes_callout.lua

Порядок важен: сперва ПЛЕЙН (лицензия + метаданные script_* + package.preload воркера),
затем обфусцированный CORE. UTF-8 без BOM, LF.

moonloader/saes_callout.lua — это ПУБЛИКУЕМЫЙ файл (его тянет апдейтер из raw). Плейн —
источник правды — лежит в src/. Запуск: python build/assemble.py (после Prometheus).
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
PLAIN = os.path.join(DIST, "saes_callout.plain.lua")
COREOBF = os.path.join(DIST, "saes_callout.core.obf.lua")
OUT = os.path.join(ROOT, "moonloader", "saes_callout.lua")


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        s = f.read()
    if s and s[0] == "﻿":
        s = s[1:]
    return s


def main():
    if not os.path.exists(COREOBF):
        print("assemble.py: НЕТ %s — сперва прогони Prometheus на core" % COREOBF)
        return 1
    plain = read(PLAIN)
    core = read(COREOBF)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(plain.rstrip("\n") + "\n\n" + core)
    print("assemble.py: готово -> %s (%d байт)" % (OUT, os.path.getsize(OUT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
