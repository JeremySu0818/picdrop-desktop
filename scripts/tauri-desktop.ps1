param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $TauriArgs
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Get-ProjectMetadata {
  $config = Get-Content -LiteralPath (Join-Path $root 'src-tauri\tauri.conf.json') -Raw | ConvertFrom-Json

  return @{
    ProductName = $config.productName
    Version = $config.version
  }
}

function Copy-ReleaseAsset($sourceRelativePath, $destinationName) {
  $source = Join-Path $root $sourceRelativePath
  if (-not (Test-Path $source)) {
    throw "Build asset was not found: $sourceRelativePath"
  }

  $output = Join-Path $root 'output'
  New-Item -ItemType Directory -Force -Path $output | Out-Null

  $destination = Join-Path $output $destinationName
  Copy-Item -LiteralPath $source -Destination $destination -Force
  Write-Output "Copied release asset: output/$destinationName"
}

function Copy-WindowsReleaseAssets {
  $metadata = Get-ProjectMetadata
  $baseName = "$($metadata.ProductName)-$($metadata.Version)-windows-x64"

  Copy-ReleaseAsset 'src-tauri\target\release\picdrop.exe' "$baseName-portable.exe"
  Copy-ReleaseAsset "src-tauri\target\release\bundle\msi\$($metadata.ProductName)_$($metadata.Version)_x64_en-US.msi" "$baseName.msi"
  Copy-ReleaseAsset "src-tauri\target\release\bundle\nsis\$($metadata.ProductName)_$($metadata.Version)_x64-setup.exe" "$baseName-setup.exe"
}

Push-Location $root
try {
  & npm run sync:page
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to sync GitHub Page source.'
  }

  & npx tauri build @TauriArgs
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }

  Copy-WindowsReleaseAssets
}
finally {
  Pop-Location
}
