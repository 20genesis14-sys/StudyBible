$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

$steps = @(
    @('fmt',    'cargo', @('fmt', '--all', '--', '--check')),
    @('clippy', 'cargo', @('clippy', '--workspace', '--all-targets', '--', '-D', 'warnings')),
    @('test',   'cargo', @('test', '--workspace')),
    @('wasm32', 'cargo', @('check', '-p', 'studybible-core', '--target', 'wasm32-unknown-unknown')),
    @('deny',   'cargo', @('deny', 'check'))
)

foreach ($s in $steps) {
    Write-Host "==> $($s[0])"
    & $s[1] @($s[2])
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $($s[0])" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}
Write-Host 'CI OK' -ForegroundColor Green
