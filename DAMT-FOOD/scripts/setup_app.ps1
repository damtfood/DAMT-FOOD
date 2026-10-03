# Usage (from repo root, PowerShell):  .\scripts\setup_app.ps1 customer
param([Parameter(Mandatory=$true)][ValidateSet('customer','admin','delivery')][string]$App)
$labels = @{ customer='DAMT Food'; admin='DAMT Food Admin'; delivery='DAMT Food Delivery' }
$root = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $root "apps\$App"
$out  = Join-Path $root "out\$App"

flutter create --org com.murugantrader.damtfood --project-name $App --platforms android $out
Copy-Item "$src\lib"          $out -Recurse -Force
Copy-Item "$src\assets"       $out -Recurse -Force
Copy-Item "$src\pubspec.yaml" $out -Force

$manifest = Join-Path $out 'android\app\src\main\AndroidManifest.xml'
$x = Get-Content $manifest -Raw
if ($x -notmatch 'android.permission.INTERNET') {
  $x = $x -replace '<application', "<uses-permission android:name=`"android.permission.INTERNET`"/>`n    <application"
}
$x = $x -replace 'android:label="[^"]*"', "android:label=`"$($labels[$App])`""
Set-Content $manifest $x

Push-Location $out
flutter pub get
dart run flutter_launcher_icons
Pop-Location
Write-Host "Done. Next: cd out\$App ; flutter build apk --release"
