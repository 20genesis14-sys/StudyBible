# flutter build web + снять из бандла assets/assets/modules/*.sbz.
# .sbz в assets нужны только нативному сидированию (Android/desktop —
# первый запуск ставит модули из бандла). На web мост качает модули из
# web/modules/ (fetch в native_bridge_web.dart), поэтому копия в
# assets/assets/modules/ — ~11 МБ мёртвого веса в каждом деплое.
# Раздача: serve_web.py (локально) или любой статик-хостинг.

[CmdletBinding()]
param(
  [string]$Flutter = 'D:\StudyBible-tools\flutter\bin\flutter.bat'
)

$ErrorActionPreference = 'Stop'
$app = Join-Path $PSScriptRoot '..\apps\studybible-flutter'

Push-Location $app
try {
  & $Flutter build web
  if ($LASTEXITCODE -ne 0) { throw "flutter build web: exit $LASTEXITCODE" }

  $seed = Join-Path $app 'build\web\assets\assets\modules'
  if (Test-Path $seed) {
    $mb = [math]::Round(((Get-ChildItem $seed -Recurse -File |
      Measure-Object Length -Sum).Sum / 1MB), 1)
    Remove-Item $seed -Recurse -Force
    Write-Host "Снято assets/assets/modules из веб-бандла: $mb МБ"
  } else {
    Write-Host 'assets/assets/modules в бандле нет — резать нечего'
  }
} finally {
  Pop-Location
}
