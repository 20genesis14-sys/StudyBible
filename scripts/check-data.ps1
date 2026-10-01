# Сверка содержимого внешних текстов после fetch-data.ps1.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dataDir = if ($env:STUDYBIBLE_DATA) { $env:STUDYBIBLE_DATA } else { Join-Path (Split-Path -Parent $repo) 'StudyBible-data' }
$srcDir = Join-Path $dataDir 'sources'
$utf8 = New-Object Text.UTF8Encoding $false
$failed = 0

function Get-Verse([string]$id, [string]$book, [int]$ch, [int]$vs) {
    $file = Get-ChildItem (Join-Path $srcDir $id) -Filter "*$book$id.usfm" | Select-Object -First 1
    if (-not $file) { return $null }
    $t = [IO.File]::ReadAllText($file.FullName, $utf8)
    $c = [regex]::Match($t, "(?s)\\c $ch\b(.*?)(?=\\c \d|\z)").Groups[1].Value
    [regex]::Match($c, "(?s)\\v $vs\b(.*?)(?=\\v \d|\z)").Groups[1].Value.Trim()
}

function Get-PlainText([string]$usfm) {
    $t = [regex]::Replace($usfm, '(?s)\\f .*?\\f\*', '')
    $t = [regex]::Replace($t, '\\\+?w ([^|\\]*)(\|[^\\]*)?\\\+?w\*', '$1')
    ([regex]::Replace($t, '\s+', ' ')).Trim()
}

function Check([string]$name, [bool]$ok) {
    Write-Host ("{0}  {1}" -f ($(if ($ok) { 'ok  ' } else { 'FAIL' })), $name)
    if (-not $ok) { $script:failed++ }
}

# Синодальный, вариант (а): имя «Иегова» хотя бы в одном из мест. Если ни в одном — заменить источник.
$places = @(@('GEN', 22, 14), @('EXO', 17, 15), @('JDG', 6, 24))
$hits = @($places | Where-Object { (Get-Verse 'russyn' $_[0] $_[1] $_[2]) -match 'Иегов' })
Check "russyn: «Иегова» в Быт 22:14 / Исх 17:15 / Суд 6:24 ($($hits.Count) из 3)" ($hits.Count -gt 0)
Check 'russyn: Быт 1:1' ((Get-Verse 'russyn' 'GEN' 1 1) -eq 'В начале сотворил Бог небо и землю.')

$protocanon = 'GEN EXO LEV NUM DEU JOS JDG RUT 1SA 2SA 1KI 2KI 1CH 2CH EZR NEH EST JOB PSA PRO ECC SNG ISA JER LAM EZK DAN HOS JOL AMO OBA JON MIC NAM HAB ZEP HAG ZEC MAL MAT MRK LUK JHN ACT ROM 1CO 2CO GAL EPH PHP COL 1TH 2TH 1TI 2TI TIT PHM HEB JAS 1PE 2PE 1JN 2JN 3JN JUD REV' -split ' '
foreach ($id in 'russyn', 'engwebp', 'eng-kjv2006') {
    $ids = Get-ChildItem (Join-Path $srcDir $id) -Filter *.usfm | ForEach-Object { ([IO.File]::ReadAllLines($_.FullName, $utf8)[0] -split ' ')[1] }
    $missing = @($protocanon | Where-Object { $ids -notcontains $_ })
    Check "${id}: все 66 книг ($($ids.Count) файлов usfm)" ($missing.Count -eq 0)
}
Check 'engwebp: Быт 1:1' ((Get-PlainText (Get-Verse 'engwebp' 'GEN' 1 1)) -eq 'In the beginning, God created the heavens and the earth.')
Check 'eng-kjv2006: Быт 1:1' ((Get-PlainText (Get-Verse 'eng-kjv2006' 'GEN' 1 1)) -eq 'In the beginning God created the heaven and the earth.')
Check 'eng-kjv2006: номера Стронга' ((Get-Verse 'eng-kjv2006' 'GEN' 1 1) -match 'strong="H7225"')

if ($failed) { Write-Host "FAILED: $failed" -ForegroundColor Red; exit 1 }
Write-Host 'DATA OK' -ForegroundColor Green
