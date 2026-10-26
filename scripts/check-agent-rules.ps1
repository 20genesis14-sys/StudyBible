# scripts/check-agent-rules.ps1 — механические проверки правил из AGENTS.md.
# Часть петли улучшения обвязки (docs/AGENT-HARNESS.md, ADR 0031):
# правила рождаются из записей BUGS.md со строкой harness-gap.
#
# NAV-1 — «Навигация в ReadingScreen» (AGENTS.md): выходы с маршрута
# только через именованные семантики _popRoute/_stackBack/_hierarchyBack
# (PopScope(canPop: false) молча глотает голые pop'ы).
#   * maybePop / pushReplacement — во всех пяти файлах ридера;
#   * Navigator.of(...).pop( — только в reading_screen.dart: в part-файлах
#     .pop() закрывает диалоги и шиты — это другие маршруты, не экран
#     чтения;
#   * легитимно: строка с _popRoute( или тело объявления
#     void _popRoute/_stackBack/_hierarchyBack (объявление на отступе 2,
#     закрывается "}" на отступе 2 — гарантирует dart format);
#   * явное исключение с обоснованием — комментарий `// nav:` в строке
#     (стиль дома, как `// SAFETY:` для unsafe).
param(
  # Корень дерева для проверки (run-eval.ps1 передаёт путь к worktree).
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
Set-Location $Root

$readerFiles = @(
  'apps/studybible-flutter/lib/screens/reading_screen.dart',
  'apps/studybible-flutter/lib/reader/chapter_renderer.dart',
  'apps/studybible-flutter/lib/reader/reader_chrome.dart',
  'apps/studybible-flutter/lib/reader/reader_controller.dart',
  'apps/studybible-flutter/lib/reader/reader_pane.dart'
)

# Диапазоны строк — тела объявлений void _popRoute/_stackBack/_hierarchyBack.
function Get-NavRegions([string[]]$Lines) {
  $ranges = @()
  $open = -1
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($open -lt 0) {
      if ($Lines[$i] -match '^\s{2}void _(popRoute|stackBack|hierarchyBack)\s*\(') { $open = $i }
    } elseif ($Lines[$i] -match '^\s{2}\}') {
      $ranges += ,@($open, $i)
      $open = -1
    }
  }
  return ,$ranges
}

$violations = @()
foreach ($rel in $readerFiles) {
  $path = Join-Path $Root $rel
  if (-not (Test-Path $path)) {
    $violations += "NAV-1 ${rel}: файл не найден"
    continue
  }
  $lines = Get-Content $path
  $regions = Get-NavRegions $lines
  $isMain = $rel -like '*screens/reading_screen.dart'
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith('//')) { continue }  # строки-комментарии
    $hits = ($line -match 'maybePop') -or ($line -match 'pushReplacement')
    if ($isMain -and $line -match 'Navigator\.of\([^)]*\)\s*\.pop\(') { $hits = $true }
    if (-not $hits) { continue }
    if ($line -match '_popRoute\(') { continue }  # обёртка на той же строке
    if ($line -match '//\s*nav:') { continue }    # явное исключение
    $inRegion = $false
    foreach ($r in $regions) {
      if ($i -ge $r[0] -and $i -le $r[1]) { $inRegion = $true; break }
    }
    if (-not $inRegion) {
      $violations += ('{0}:{1}: NAV-1: {2}' -f $rel, ($i + 1), $trimmed)
    }
  }
}

if ($violations.Count -gt 0) {
  Write-Host ("НАРУШЕНИЯ AGENT-RULES ({0}):" -f $violations.Count) -ForegroundColor Red
  foreach ($v in $violations) { Write-Host "  $v" -ForegroundColor Red }
  Write-Host 'Правила: docs/AGENT-HARNESS.md, механический слой.'
  exit 1
}
Write-Host 'AGENT-RULES OK' -ForegroundColor Green
exit 0
