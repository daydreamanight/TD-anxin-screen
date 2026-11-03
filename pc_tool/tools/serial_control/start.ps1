param([int]$Port=8770,[switch]$NoBrowser)
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$python=(Get-Command python -ErrorAction Stop).Source
Push-Location $project
try {
 Write-Host '安芯讯屏：独立控制台，默认不打开串口、不发送数据。'
 if($NoBrowser){& $python -X utf8 -m tools.serial_control.server --port $Port}
 else{& $python -X utf8 -m tools.serial_control.server --port $Port --open-browser}
}finally{Pop-Location}
exit $LASTEXITCODE
