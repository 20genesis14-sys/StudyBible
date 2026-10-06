# scripts/check-apk-api.ps1 — проверка целевого Android API собранных .so.
# Наш мост (libstudybible_flutter_bridge.so) обязан быть линкован под API
# не выше -MaxApi (minSdk приложения), иначе на Android < 15 dlopen падает
# (открытый вопрос № 29). Сторонние готовые .so (libflutter, libsqlite3,
# sherpa/onnxruntime) мы не линкуем — для них только предупреждение.
#
# API-уровень читается из .note.android.ident: первые 4 байта
# description data, little-endian.
param(
  [string]$Apk = 'apps\studybible-flutter\build\app\outputs\flutter-apk\app-release.apk',
  [int]$MaxApi = 26
)

$ErrorActionPreference = 'Stop'

# --- llvm-readelf из NDK ---
function Find-ReadElf {
  $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME,
                'D:\StudyBible-tools\android-sdk') |
    Where-Object { $_ -and (Test-Path $_) }
  foreach ($root in $sdkRoots) {
    $ndkDir = Join-Path $root 'ndk'
    if (-not (Test-Path $ndkDir)) { continue }
    $ndks = Get-ChildItem $ndkDir -Directory | Sort-Object Name -Descending
    foreach ($ndk in $ndks) {
      $p = Join-Path $ndk.FullName 'toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe'
      if (Test-Path $p) { return $p }
    }
  }
  # Фоллбэк: llvm-readelf в PATH.
  $cmd = Get-Command llvm-readelf -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw 'llvm-readelf не найден: задайте ANDROID_SDK_ROOT/ANDROID_HOME или положите NDK в D:\StudyBible-tools\android-sdk\ndk'
}

# --- API из .note.android.ident ---
function Get-SoApi([string]$ReadElf, [string]$So) {
  $out = & $ReadElf -n $So 2>$null
  foreach ($line in $out) {
    if ($line -match 'description data:\s*(.*)$') {
      $bytes = ($Matches[1] -split '\s+') |
        Where-Object { $_ -match '^[0-9a-fA-F]{2}$' }
      if ($bytes.Count -ge 4) {
        return [BitConverter]::ToUInt32(
          [byte[]]($bytes[0..3] | ForEach-Object { [Convert]::ToByte($_, 16) }), 0)
      }
      return $null
    }
  }
  return $null  # секции нет — сборка без NDK-ноты
}

$apkPath = Resolve-Path $Apk
$readelf = Find-ReadElf
Write-Host "llvm-readelf: $readelf"
Write-Host "APK: $apkPath"

# --- распаковка lib/**.so во временный каталог ---
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("apk-api-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $zip = Join-Path $tmp 'app.zip'
  Copy-Item $apkPath $zip
  Expand-Archive $zip -DestinationPath $tmp -Force
  $sos = Get-ChildItem (Join-Path $tmp 'lib') -Recurse -Filter '*.so'
  if (-not $sos) { throw 'в APK не найдено lib/**/*.so' }

  $fail = $false
  '{0,-44} {1,-26} {2}' -f 'Файл', 'ABI', 'API'
  foreach ($so in ($sos | Sort-Object FullName)) {
    $rel = $so.FullName.Substring($tmp.Length).TrimStart('\', '/')
    $abi = ($rel -split '[\\/]')[1]
    $api = Get-SoApi $readelf $so.FullName
    $apiText = if ($null -eq $api) { 'нет .note.android.ident' } else { $api }
    '{0,-44} {1,-26} {2}' -f $so.Name, $abi, $apiText
    if ($null -ne $api -and $api -gt $MaxApi) {
      if ($so.Name -eq 'libstudybible_flutter_bridge.so') {
        Write-Host "  ОШИБКА: мост линкован под API $api > $MaxApi"
        $fail = $true
      } else {
        Write-Host "  предупреждение: сторонний .so под API $api > $MaxApi (нами не линкуется)"
      }
    }
  }
  if ($fail) { exit 1 }
  Write-Host 'OK: libstudybible_flutter_bridge.so не выше MaxApi'
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
