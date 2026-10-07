# Скачивает внешние тексты из data/sources.json в каталог данных вне репозитория
# и сверяет SHA-256. -Pin закрепляет хэши в sources.json (первый раз или при обновлении источника).
param([switch]$Pin)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repo 'data\sources.json'
$dataDir = if ($env:STUDYBIBLE_DATA) { $env:STUDYBIBLE_DATA } else { Join-Path (Split-Path -Parent $repo) 'StudyBible-data' }
$srcDir = Join-Path $dataDir 'sources'
New-Item -ItemType Directory -Force $srcDir | Out-Null

$manifest = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json
$failed = $false

foreach ($s in $manifest.sources) {
    $zip = Join-Path $srcDir "$($s.id).zip"
    if (-not (Test-Path $zip) -or $Pin) {
        Write-Host "==> download $($s.id)"
        Invoke-WebRequest -UseBasicParsing $s.url -OutFile $zip
    }
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Pin) {
        $s.sha256 = $hash
    } elseif ($s.sha256 -ne $hash) {
        Write-Host "SHA-256 mismatch: $($s.id) expected '$($s.sha256)' got '$hash'" -ForegroundColor Red
        $failed = $true
        continue
    }
    $dest = Join-Path $srcDir $s.id
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive -Path $zip -DestinationPath $dest
    # "flatten": true — архив содержит единственную папку-обёртку
    # (OSHB-v.2.2/, el-x-koine_ugnt/): поднимаем её содержимое в <id>.
    if ($s.flatten) {
        $kids = @(Get-ChildItem $dest)
        if ($kids.Count -eq 1 -and $kids[0].PSIsContainer) {
            Move-Item (Join-Path $kids[0].FullName '*') $dest
            Remove-Item $kids[0].FullName
        }
    }
    # "remove": список файлов внутри распаковки, не являющихся входом
    # конвертера (напр. VerseMap.xml у OSHB — это не OSIS-текст).
    foreach ($junk in @($s.remove)) {
        $p = Join-Path $dest $junk
        if (Test-Path $p) { Remove-Item -Force $p }
    }
    Write-Host "ok  $($s.id) $hash"
}

if ($Pin) {
    $json = $manifest | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($manifestPath, $json + "`n", (New-Object Text.UTF8Encoding $false))
    Write-Host "pinned -> $manifestPath"
}
if ($failed) { exit 1 }
Write-Host "data: $srcDir"
