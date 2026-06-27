# SAES Callout release build: split -> obfuscate (Prometheus) -> assemble -> syntax-check.
# Source of truth: src/saes_callout.lua (плейн). Этот скрипт собирает обфусцированный
# moonloader/saes_callout.lua, который и раздаётся / тянется автообновлением.
#
# Run:  powershell -ExecutionPolicy Bypass -File build/build.ps1
# (ASCII only on purpose: Windows PowerShell 5.1 parses .ps1 in the ANSI codepage.)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Dist = Join-Path $Root 'dist'

# luajit гоняет Prometheus (на выходе портируемый ИСХОДНИК, версия luajit роли не играет).
$LJ = 'C:\Users\sexorcist\AppData\Local\Programs\LuaJIT\bin\luajit.exe'
if (-not (Test-Path $LJ)) {
  $cmd = Get-Command luajit -ErrorAction SilentlyContinue
  if ($cmd) { $LJ = $cmd.Source } else { throw 'luajit.exe not found' }
}

$Prom    = Join-Path $PSScriptRoot 'Prometheus\cli.lua'
$Config  = Join-Path $PSScriptRoot 'prometheus_config.lua'
$Core    = Join-Path $Dist 'saes_callout.core.lua'
$CoreObf = Join-Path $Dist 'saes_callout.core.obf.lua'
$Test    = Join-Path $Dist 'saes_callout.test.lua'
$Final   = Join-Path $Root 'moonloader\saes_callout.lua'

if (-not (Test-Path $Prom)) { throw "Prometheus not found at $Prom" }

Write-Host '[1/5] split (plain | core)...' -ForegroundColor Cyan
python (Join-Path $PSScriptRoot 'split.py')
if ($LASTEXITCODE -ne 0) { throw 'split.py failed' }

Write-Host '[2/5] syntax check source (plain+core, pre-obfuscation)...' -ForegroundColor Cyan
& $LJ '-e' ("assert(loadfile([[$Test]])); io.write('SRC_SYNTAX_OK\n')")
if ($LASTEXITCODE -ne 0) { throw 'source (test.lua) failed to parse' }

Write-Host '[3/5] obfuscate core (Prometheus)...' -ForegroundColor Cyan
if (Test-Path $CoreObf) { Remove-Item $CoreObf -Force }
& $LJ $Prom '--config' $Config '--Lua51' '--nocolors' '--out' $CoreObf $Core
if (-not (Test-Path $CoreObf)) { throw 'Prometheus did not produce output' }

Write-Host '[4/5] assemble plain + core.obf -> moonloader/saes_callout.lua...' -ForegroundColor Cyan
python (Join-Path $PSScriptRoot 'assemble.py')
if ($LASTEXITCODE -ne 0) { throw 'assemble.py failed' }

Write-Host '[5/5] syntax check final...' -ForegroundColor Cyan
& $LJ '-e' ("assert(loadfile([[$Final]])); io.write('FINAL_SYNTAX_OK\n')")
if ($LASTEXITCODE -ne 0) { throw 'final file failed to parse' }

# Guard: убеждаемся, что плейн-маркер автообновления уцелел, а тело воркера НЕ зашифровано.
$txt = [System.IO.File]::ReadAllText($Final, [System.Text.Encoding]::UTF8)
if (-not $txt.Contains('SAES Callout System')) { throw 'updater marker "SAES Callout System" missing from final' }
if (-not $txt.Contains("package.preload['saes_callout.httpworker']")) { throw 'plain effil worker missing from final' }

$sz = [int]((Get-Item $Final).Length / 1024)
Write-Host ("DONE. moonloader/saes_callout.lua ($sz KB) собран и проверен.") -ForegroundColor Green
