# scripts/run-eval.ps1 — подготовка и судейство eval-прогона (ADR 0031,
# docs/AGENT-HARNESS.md). Карточка — evals/tasks/*.md (формат: evals/README.md).
#
#   -Setup : git worktree + ветка eval/<id>-<label> от Base карточки
#   -Judge : стоящие проверки (agent-rules, flutter analyze, ci.ps1)
#            + механические чеки карточки; запись в evals/results/
#
# Между Setup и Judge прогон делает сессия агента в worktree: ей дают
# раздел Task карточки. Метка Label — вариант обвязки: baseline или имя
# кандидата (см. AGENT-HARNESS.md, шаги Probe/Compare).
#
# Нативные вызовы идут под $ErrorActionPreference='Continue': в PS 5.1
# поток stderr нативной команды при 'Stop' бросает NativeCommandError.
param(
  [Parameter(Mandatory = $true)][string]$Task,
  [string]$Label = 'baseline',
  [switch]$Setup,
  [switch]$Judge,
  [string]$Worktree = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$taskPath = if ([IO.Path]::IsPathRooted($Task)) { $Task } else { Join-Path $repo $Task }
if (-not (Test-Path $taskPath)) { throw "карточка не найдена: $taskPath" }

# git может отсутствовать в PATH чистой сессии — как в ci.ps1.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

# --- шапка карточки ---
$id = $null; $version = $null; $base = $null
foreach ($line in (Get-Content $taskPath -Encoding UTF8)) {
  if ($line -match '^- Id:\s*(.+)$') { $id = $Matches[1].Trim() }
  elseif ($line -match '^- Version:\s*(.+)$') { $version = $Matches[1].Trim() }
  elseif ($line -match '^- Base:\s*(\S+)') { $base = $Matches[1].Trim() }
}
if (-not $id -or -not $base) { throw 'в карточке нет Id: или Base:' }

$wtRoot = 'D:\StudyBible-eval'
$wt = if ($Worktree) { $Worktree } else { Join-Path $wtRoot "$id-$Label" }

if ($Setup) {
  if (Test-Path $wt) { throw "worktree уже есть: $wt (удалите или передайте -Worktree)" }
  git worktree add -b "eval/$id-$Label" $wt $base
  if ($LASTEXITCODE -ne 0) { throw 'git worktree add не удался' }
  Write-Host "Worktree : $wt"
  Write-Host "Ветка    : eval/$id-$Label (от $base)"
  Write-Host "Дальше   : сессия агента в worktree — дайте ей раздел Task карточки:"
  Write-Host "  $taskPath"
  Write-Host "Затем    : run-eval.ps1 -Task <карточка> -Label $Label -Judge"
  exit 0
}

if (-not $Judge) { throw 'укажите -Setup или -Judge' }
if (-not (Test-Path $wt)) { throw "worktree не найден: $wt" }

# --- журнал результатов ---
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Name, [bool]$Pass, [string]$Detail) {
  $script:results.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail })
}

# 1. agent-rules (быстро) — скрипт основного репо по дереву worktree.
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try {
  & (Join-Path $repo 'scripts\check-agent-rules.ps1') -Root $wt 2>&1 | Write-Host
  $code = $LASTEXITCODE
} finally { $ErrorActionPreference = $prevEap }
Add-Result 'agent-rules' ($code -eq 0) ''

# 2. flutter analyze в приложении worktree (--no-fatal-infos: info-линты
#    на базах толерантны, фейлиться должны warnings/errors).
$flutter = 'D:\StudyBible-tools\flutter\bin\flutter.bat'
$appDir = Join-Path $wt 'apps\studybible-flutter'
if (-not (Test-Path $flutter)) {
  Add-Result 'flutter analyze' $false 'flutter.bat не найден'
} elseif (-not (Test-Path $appDir)) {
  Add-Result 'flutter analyze' $true 'нет каталога приложения (rust-задача)'
} else {
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    Push-Location $appDir
    & $flutter analyze --no-fatal-infos 2>&1 | Select-Object -Last 5 | Write-Host
    $code = $LASTEXITCODE
  } finally { Pop-Location; $ErrorActionPreference = $prevEap }
  Add-Result 'flutter analyze' ($code -eq 0) "exit=$code"
}

# 3. ci.ps1 worktree (cargo: fmt/clippy/test/wasm32/deny) — долгий шаг.
$ciWt = Join-Path $wt 'scripts\ci.ps1'
if (-not (Test-Path $ciWt)) {
  Add-Result 'ci.ps1' $false 'scripts/ci.ps1 нет в worktree'
} else {
  # На старых базах ci.ps1 ещё без шага agent-rules — это и учтено выше.
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $ciWt 2>&1 |
      Select-Object -Last 5 | Write-Host
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prevEap }
  Add-Result 'ci.ps1' ($code -eq 0) "exit=$code"
}

# 4. механические чеки карточки: `- [ ] описание — `команда` → ожидание`.
$inChecks = $false
foreach ($line in (Get-Content $taskPath -Encoding UTF8)) {
  if ($line -match '^## ') { $inChecks = ($line -match '^## Checks'); continue }
  if (-not $inChecks) { continue }
  if ($line -notmatch '^- \[ \] (.+)$') { continue }
  $item = $Matches[1].Trim()
  if ($item -notmatch '`([^`]+)`') { continue }  # ручной пункт — без команды
  $cmd = $Matches[1]
  $expect = if ($item -match '→\s*exit\s*!=\s*0') { 'nonzero' } else { 'zero' }
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  Push-Location $wt
  try {
    $out = Invoke-Expression $cmd 2>&1
    $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
  } finally { Pop-Location; $ErrorActionPreference = $prevEap }
  $pass = if ($expect -eq 'zero') { $code -eq 0 } else { $code -ne 0 }
  $firstLine = ($out | Where-Object { $_ }) |
    Select-Object -First 1 | ForEach-Object { "$_" }
  Add-Result $item $pass ("exit=$code $($firstLine)")
}

# --- запись результата в основной репо ---
$dir = Join-Path $repo 'evals\results'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$date = Get-Date -Format 'yyyy-MM-dd'
$record = Join-Path $dir "$date-$id-$Label.md"
# Внимание: @($list) вокруг List[object] бросает ArgumentException в этом
# хосте PS 5.1 — используем ToArray()/конвейер.
$mech = $results.ToArray()
$passed = ($mech | Where-Object { $_.Pass }).Count
$lines = @(
  "# $id — $Label ($date)",
  '',
  "- Card: evals/tasks/$id.md (v$version)",
  "- Worktree: $wt, ветка eval/$id-$Label (base $base)",
  "- Judge: $passed/$($mech.Count) проверок пройдено",
  '',
  '| Проверка | Результат | Детали |',
  '|---|---|---|'
)
foreach ($r in $results) {
  $mark = if ($r.Pass) { '✅' } else { '❌' }
  $lines += ('| {0} | {1} | {2} |' -f
    ($r.Name -replace '\|', '/'), $mark, ($r.Detail -replace '\|', '/'))
}
$lines += @(
  '',
  'Verdict: (заполнить вручную — AGENT-HARNESS.md, шаг Compare)',
  'Notes:'
)
$lines | Set-Content $record -Encoding UTF8
Write-Host ''
Write-Host ("Результат: {0}/{1} — запись: {2}" -f $passed, $mech.Count, $record)
if ($passed -lt $mech.Count) { exit 1 }
exit 0
