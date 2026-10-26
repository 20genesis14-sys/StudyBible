# Скачивает внешние тексты из data/sources.json в каталог данных вне репозитория
# и сверяет SHA-256. -Pin закрепляет хэши в sources.json (первый раз или при обновлении источника).
# -Only <id,...> — обработать только перечисленные источники.
param([switch]$Pin, [string[]]$Only)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repo 'data\sources.json'
$dataDir = if ($env:STUDYBIBLE_DATA) { $env:STUDYBIBLE_DATA } else { Join-Path (Split-Path -Parent $repo) 'StudyBible-data' }
$srcDir = Join-Path $dataDir 'sources'
New-Item -ItemType Directory -Force $srcDir | Out-Null

$manifest = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json
if ($Only) {
    # через -File список "a,b" приходит одной строкой — разбираем вручную
    $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $unknown = @($Only | Where-Object { $_ -notin @($manifest.sources.id) })
    if ($unknown) { throw "неизвестный id в -Only: $($unknown -join ', ')" }
}
$failed = $false

foreach ($s in $manifest.sources) {
    if ($Only -and $s.id -notin $Only) { continue }
    # "dest": подкаталог в sources/ (напр. strongs/stepbible); по умолчанию — id.
    $sub = if ($s.dest) { $s.dest } else { $s.id }
    # "files": набор отдельных файлов вместо zip (напр. файлы репозитория GitHub по путям).
    if ($s.files) {
        $entryOk = $true
        foreach ($f in $s.files) {
            $target = Join-Path $srcDir (Join-Path $sub $f.path)
            New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
            if (-not (Test-Path $target) -or $Pin) {
                Write-Host "==> download $($s.id)/$($f.path)"
                Invoke-WebRequest -UseBasicParsing $f.url -OutFile $target
            }
            $hash = (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($Pin) {
                $f.sha256 = $hash
            } elseif ($f.sha256 -ne $hash) {
                Write-Host "SHA-256 mismatch: $($s.id)/$($f.path) expected '$($f.sha256)' got '$hash'" -ForegroundColor Red
                $entryOk = $false
            }
        }
        if (-not $entryOk) { $failed = $true; continue }
        Write-Host "ok  $($s.id) $(@($s.files).Count) files"
        continue
    }
    $zip = Join-Path $srcDir "$sub.zip"
    New-Item -ItemType Directory -Force (Split-Path -Parent $zip) | Out-Null
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
    $dest = Join-Path $srcDir $sub
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
    foreach ($junk in @($s.remove | Where-Object { $_ })) {
        $p = Join-Path $dest $junk
        if (Test-Path $p) { Remove-Item -Force $p }
    }
    Write-Host "ok  $($s.id) $hash"
}

if ($Pin) {
    $json = $manifest | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($manifestPath, $json + "`n", (New-Object Text.UTF8Encoding $false))
    Write-Host "pinned -> $manifestPath"
}
if ($failed) { exit 1 }
Write-Host "data: $srcDir"
