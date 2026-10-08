param([string]$DevEco = 'E:\Program\Huawei\DevEco Studio', [switch]$Tests)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$previousSdk = $env:DEVECO_SDK_HOME
$previousJava = $env:JAVA_HOME
Push-Location -LiteralPath $workspace
try {
  $env:DEVECO_SDK_HOME = Join-Path $DevEco 'sdk'
  $env:JAVA_HOME = Join-Path $DevEco 'jbr'
  $taskTarget = if ($Tests) { 'entry@ohosTest' } else { 'entry@default' }
  & (Join-Path $DevEco 'tools/node/node.exe') (Join-Path $DevEco 'tools/hvigor/bin/hvigorw.js') --mode module -p product=default -p "module=$taskTarget" assembleHap --no-daemon
  if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS build failed.' }
} finally { $env:DEVECO_SDK_HOME = $previousSdk; $env:JAVA_HOME = $previousJava; Pop-Location }
