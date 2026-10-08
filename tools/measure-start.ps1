$exe='D:\StudyBible\release-1.0\windows\studybible.exe'
for($i=0;$i -lt 4;$i++){
  Get-Process studybible -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $p=Start-Process $exe -PassThru -WorkingDirectory (Split-Path $exe)
  while(-not $p.HasExited -and $p.MainWindowHandle -eq 0){$p.Refresh(); Start-Sleep -Milliseconds 10}
  $sw.Stop()
  Write-Output ("run $i : " + $sw.ElapsedMilliseconds + " ms до появления окна")
  Start-Sleep -Seconds 3
}
Get-Process studybible -ErrorAction SilentlyContinue | Stop-Process -Force
