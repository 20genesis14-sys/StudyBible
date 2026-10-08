$exe='C:\StudyBible-tools\empty_app\build\windows\x64\runner\Release\empty_app.exe'
for($i=0;$i -lt 4;$i++){
  Get-Process empty_app -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 600
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $p=Start-Process $exe -PassThru -WorkingDirectory (Split-Path $exe)
  while(-not $p.HasExited -and $p.MainWindowHandle -eq 0){$p.Refresh(); Start-Sleep -Milliseconds 10}
  $sw.Stop()
  Write-Output ("run $i : " + $sw.ElapsedMilliseconds + " ms")
  Start-Sleep -Seconds 2
}
Get-Process empty_app -ErrorAction SilentlyContinue | Stop-Process -Force
