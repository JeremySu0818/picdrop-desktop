param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('init', 'dev', 'build', 'run')]
  [string] $Command,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $TauriArgs
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$defaultSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { $defaultSdk }
$ndk = if ($env:NDK_HOME) { $env:NDK_HOME } else { Join-Path $sdk 'ndk\25.2.9519653' }

if (-not (Test-Path $sdk)) {
  throw "Android SDK not found at '$sdk'. Install Android Studio or set ANDROID_HOME."
}

if (-not (Test-Path $ndk)) {
  throw "Android NDK not found at '$ndk'. Install it with sdkmanager or set NDK_HOME."
}

$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:NDK_HOME = $ndk

$paths = @(
  (Join-Path $sdk 'cmdline-tools\latest\bin'),
  (Join-Path $sdk 'platform-tools'),
  $ndk
) | Where-Object { Test-Path $_ }

$env:Path = (($paths + @($env:Path)) -join ';')

function Get-LatestBuildTool($toolName) {
  $tool = Get-ChildItem -Path (Join-Path $sdk 'build-tools') -Recurse -Filter $toolName -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1

  if (-not $tool) {
    throw "Android build tool '$toolName' was not found under '$sdk\build-tools'."
  }

  return $tool.FullName
}

function Sync-AndroidLauncherIcon {
  $sourceIcon = Join-Path $root 'src-tauri\icons\icon.png'
  $resDir = Join-Path $root 'src-tauri\gen\android\app\src\main\res'

  if (-not (Test-Path $sourceIcon)) {
    throw "Android launcher icon source not found: $sourceIcon"
  }

  if (-not (Test-Path $resDir)) {
    return
  }

  $magick = Get-Command magick -ErrorAction SilentlyContinue
  if (-not $magick) {
    throw 'ImageMagick magick.exe is required to generate Android launcher icons from src-tauri\icons\icon.png.'
  }

  $sizes = @{
    'mipmap-mdpi' = 48
    'mipmap-hdpi' = 72
    'mipmap-xhdpi' = 96
    'mipmap-xxhdpi' = 144
    'mipmap-xxxhdpi' = 192
  }

  foreach ($density in $sizes.Keys) {
    $dir = Join-Path $resDir $density
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $size = $sizes[$density]

    foreach ($name in @('ic_launcher.png', 'ic_launcher_round.png', 'ic_launcher_foreground.png')) {
      & $magick.Source $sourceIcon -resize "${size}x${size}" (Join-Path $dir $name)
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate Android launcher icon '$density/$name'."
      }
    }
  }

  Remove-Item -LiteralPath (Join-Path $resDir 'drawable\ic_launcher_background.xml') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $resDir 'drawable-v24\ic_launcher_foreground.xml') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $resDir 'mipmap-anydpi-v26\ic_launcher.xml') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $resDir 'mipmap-anydpi-v26\ic_launcher_round.xml') -Force -ErrorAction SilentlyContinue

  Write-Output "Android launcher icon synced from $sourceIcon"
}

function New-ReleaseKeystoreIfMissing {
  $signingDir = Join-Path $root 'src-tauri\gen\android\signing'
  $keystore = Join-Path $signingDir 'picdrop-release.keystore'
  $propertiesPath = Join-Path $signingDir 'release-signing.properties'

  if (-not (Test-Path $signingDir)) {
    New-Item -ItemType Directory -Force -Path $signingDir | Out-Null
  }

  if (-not (Test-Path $propertiesPath)) {
    $storePasswordBytes = [byte[]]::new(24)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
      $rng.GetBytes($storePasswordBytes)
    }
    finally {
      $rng.Dispose()
    }
    $storePassword = [Convert]::ToBase64String($storePasswordBytes)
    $keyPassword = $storePassword
    $alias = 'picdrop-release'

    $properties = @(
      "storeFile=$keystore",
      "storePassword=$storePassword",
      "keyAlias=$alias",
      "keyPassword=$keyPassword"
    )
    Set-Content -LiteralPath $propertiesPath -Value ($properties -join "`n") -NoNewline
  }

  $props = @{}
  Get-Content -LiteralPath $propertiesPath | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+?)\s*=\s*(.*)\s*$') {
      $props[$matches[1].Trim()] = $matches[2].Trim()
    }
  }

  if (-not (Test-Path $props.storeFile)) {
    & keytool `
      -genkeypair `
      -v `
      -keystore $props.storeFile `
      -storepass $props.storePassword `
      -alias $props.keyAlias `
      -keypass $props.keyPassword `
      -keyalg RSA `
      -keysize 4096 `
      -validity 10000 `
      -dname 'CN=PicDrop, OU=PicDrop, O=PicDrop, L=Taipei, ST=Taiwan, C=TW'

    if ($LASTEXITCODE -ne 0) {
      throw 'Failed to generate Android release keystore.'
    }
  }

  return $propertiesPath
}

function Get-SigningProperties($propertiesPath) {
  $props = @{}
  Get-Content -LiteralPath $propertiesPath | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+?)\s*=\s*(.*)\s*$') {
      $props[$matches[1].Trim()] = $matches[2].Trim()
    }
  }

  return $props
}

function Sign-ReleaseApk {
  $unsignedApk = Join-Path $root 'src-tauri\gen\android\app\build\outputs\apk\universal\release\app-universal-release-unsigned.apk'
  if (-not (Test-Path $unsignedApk)) {
    return
  }

  $propertiesPath = New-ReleaseKeystoreIfMissing
  $props = Get-SigningProperties $propertiesPath
  $zipalign = Get-LatestBuildTool 'zipalign.exe'
  $apksigner = Get-LatestBuildTool 'apksigner.bat'
  $alignedApk = Join-Path (Split-Path -Parent $unsignedApk) 'app-universal-release-aligned.apk'
  $signedApk = Join-Path (Split-Path -Parent $unsignedApk) 'app-universal-release-signed.apk'

  Remove-Item -LiteralPath $alignedApk, $signedApk -Force -ErrorAction SilentlyContinue

  & $zipalign -p -f 4 $unsignedApk $alignedApk
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to zipalign Android release APK.'
  }

  & $apksigner sign `
    --ks $props.storeFile `
    --ks-pass "pass:$($props.storePassword)" `
    --ks-key-alias $props.keyAlias `
    --out $signedApk `
    $alignedApk

  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to sign Android release APK.'
  }

  & $apksigner verify --verbose $signedApk
  if ($LASTEXITCODE -ne 0) {
    throw 'Signed Android release APK verification failed.'
  }

  Write-Output "Signed installable release APK: $signedApk"
}

function Sync-GitHubPage {
  Push-Location $root
  try {
    & npm run sync:page
    if ($LASTEXITCODE -ne 0) {
      throw 'Failed to sync GitHub Page source.'
    }
  }
  finally {
    Pop-Location
  }
}

$mainstreamTargets = @('aarch64', 'x86_64')
$hasExplicitTarget = $TauriArgs | Where-Object { $_ -eq '-t' -or $_ -eq '--target' }
$hasExplicitOutput = $TauriArgs | Where-Object { $_ -eq '--apk' -or $_ -eq '--aab' -or $_ -eq '--debug' }

if ($Command -eq 'build' -and -not $hasExplicitTarget) {
  $TauriArgs = @('--target') + $mainstreamTargets + $TauriArgs
}

if ($Command -eq 'build' -and -not $hasExplicitOutput) {
  $TauriArgs = @('--apk') + $TauriArgs
}

if ($Command -eq 'build' -or $Command -eq 'dev' -or $Command -eq 'run') {
  Sync-GitHubPage
  Sync-AndroidLauncherIcon
}

& npx tauri android $Command @TauriArgs
$exitCode = $LASTEXITCODE

if ($exitCode -eq 0 -and $Command -eq 'build' -and -not ($TauriArgs | Where-Object { $_ -eq '--debug' })) {
  Sign-ReleaseApk
}

exit $exitCode
