-- Конфиг обфускации ObjMapper (Prometheus). Цель: средне-высокая защита, совместимость
-- с MoonLoader/LuaJIT (любая версия — на выходе ИСХОДНИК).
--
-- ВАЖНО: Vmify (VM-виртуализация) НЕ используется — на коде такого размера LuaJIT не
-- может загрузить результат ("control structure too long": VM-диспетчер превышает лимит
-- размера структуры). Достижимый потолок здесь:
--   EncryptStrings   — строки/URL/эндпоинты зашифрованы, расшифровка в рантайме
--   ConstantArray    — все строковые константы вынесены в перемешанный пул (по индексу)
--   NumbersToExpr    — числовые литералы → выражения
--   Rename (Mangled) — все имена переменных/функций → мусор
-- AntiTamper тоже убран (ломает загрузку/reload, слабо мешает непрофи).
return {
  LuaVersion = "Lua51",
  VarNamePrefix = "",
  NameGenerator = "MangledShuffled",
  PrettyPrint = false,
  Seed = 0,
  Steps = {
    { Name = "EncryptStrings", Settings = {} },
    {
      Name = "ConstantArray",
      Settings = {
        Threshold = 1,
        StringsOnly = true,
        Shuffle = true,
        Rotate = true,
        LocalWrapperThreshold = 0,
      },
    },
    { Name = "NumbersToExpressions", Settings = {} },
  },
}
