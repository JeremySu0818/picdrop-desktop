$ErrorActionPreference = 'Stop'

$repoUrl = 'https://github.com/JeremySu0818/picdrop.jeremysu0818.github.io.git'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('picdrop-page-' + [System.Guid]::NewGuid())
$clone = Join-Path $tmp 'repo'

function Remove-PathIfExists($path) {
  if (Test-Path $path) {
    Remove-Item -LiteralPath $path -Recurse -Force
  }
}

function Copy-Directory($source, $destination) {
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
}

function Replace-Text($path, $oldValue, $newValue) {
  $content = Get-Content -LiteralPath $path -Raw
  $content = $content.Replace($oldValue, $newValue)
  Set-Content -LiteralPath $path -Value $content -NoNewline
}

function Get-Sha256Hash($path) {
  $stream = [System.IO.File]::OpenRead($path)
  try {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
      return [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
    }
    finally {
      $sha256.Dispose()
    }
  }
  finally {
    $stream.Dispose()
  }
}

function Apply-TauriDownloadPatch($path) {
  $content = Get-Content -LiteralPath $path -Raw
  $content = "import { isTauri } from '@tauri-apps/api/core';`nimport { save } from '@tauri-apps/plugin-dialog';`nimport { writeFile } from '@tauri-apps/plugin-fs';`n`n" + $content
  $content = $content -replace '(?ms)export function downloadBlob\(blob, filename\) \{\s*const url = URL\.createObjectURL\(blob\);\s*const link = document\.createElement\(''a''\);\s*link\.href = url;\s*link\.download = filename;\s*document\.body\.append\(link\);\s*link\.click\(\);\s*link\.remove\(\);\s*window\.setTimeout\(\(\) => URL\.revokeObjectURL\(url\), 1000\);\s*\}', @'
function isTauriRuntime() {
  return isTauri();
}

function getExtension(filename) {
  const cleanName = String(filename || '');
  const dotIndex = cleanName.lastIndexOf('.');
  if (dotIndex <= 0 || dotIndex === cleanName.length - 1) {
    return null;
  }

  return cleanName.slice(dotIndex + 1);
}

function getSaveFilters(filename) {
  const extension = getExtension(filename);
  if (!extension) {
    return [];
  }

  return [
    {
      name: `${extension.toUpperCase()} file`,
      extensions: [extension],
    },
  ];
}

async function saveBlobWithTauriDialog(blob, filename) {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  if (bytes.byteLength === 0) {
    throw new Error('Downloaded file is empty.');
  }

  const path = await save({
    defaultPath: filename,
    filters: getSaveFilters(filename),
  });

  if (!path) {
    return false;
  }

  await writeFile(path, bytes);
  return true;
}

function downloadBlobWithBrowser(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export async function downloadBlob(blob, filename) {
  if (isTauriRuntime()) {
    return saveBlobWithTauriDialog(blob, filename);
  }

  downloadBlobWithBrowser(blob, filename);
  return true;
}
'@
  Set-Content -LiteralPath $path -Value $content -NoNewline
}

function Sync-TauriIconsFromPage($faviconPath) {
  $iconsDir = Join-Path $root 'src-tauri\icons'
  $existingIcon = Join-Path $iconsDir 'icon.png'
  $sourceHashPath = Join-Path $iconsDir '.source-favicon.sha256'
  $newHash = Get-Sha256Hash $faviconPath
  if ((Test-Path $existingIcon) -and (Test-Path $sourceHashPath)) {
    $existingHash = (Get-Content -LiteralPath $sourceHashPath -Raw).Trim()
    if ($newHash -eq $existingHash) {
      Write-Output "Tauri icons already match $faviconPath"
      return
    }
  }

  $magick = Get-Command magick -ErrorAction SilentlyContinue
  if (-not $magick) {
    throw 'ImageMagick magick.exe is required to generate Tauri icons from the GitHub Page favicon.'
  }

  $iconPng = Join-Path $tmp 'picdrop-icon.png'
  & $magick.Source "$faviconPath[5]" -background none -resize 1024x1024 $iconPng
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to convert GitHub Page favicon into a PNG icon.'
  }

  Push-Location $root
  try {
    & npx tauri icon $iconPng --output $iconsDir
    if ($LASTEXITCODE -ne 0) {
      throw 'Failed to generate Tauri icons from the GitHub Page favicon.'
    }
    Set-Content -LiteralPath $sourceHashPath -Value $newHash -NoNewline
  }
  finally {
    Pop-Location
  }
}

try {
  git clone --depth 1 $repoUrl $clone

  $src = Join-Path $root 'src'
  Remove-PathIfExists (Join-Path $src 'js')
  Remove-PathIfExists (Join-Path $src 'css')
  Remove-PathIfExists (Join-Path $src 'assets\images')
  Remove-PathIfExists (Join-Path $src 'assets\favicon.ico')

  Copy-Directory (Join-Path $clone 'static\js') (Join-Path $src 'js')
  Copy-Directory (Join-Path $clone 'static\css') (Join-Path $src 'css')
  Copy-Directory (Join-Path $clone 'static\images') (Join-Path $src 'assets\images')
  $favicon = Join-Path $clone 'favicon.ico'
  Copy-Item -LiteralPath $favicon -Destination (Join-Path $src 'assets\favicon.ico') -Force
  Sync-TauriIconsFromPage $favicon

  $fonts = Join-Path $src 'assets\fonts'
  New-Item -ItemType Directory -Force -Path $fonts | Out-Null
  Invoke-WebRequest -Uri 'https://fonts.gstatic.com/s/outfit/v15/QGYyz_MVcBeNP4NjuGObqx1XmO1I4QK1C4E.ttf' -OutFile (Join-Path $fonts 'outfit-500.ttf')
  Invoke-WebRequest -Uri 'https://fonts.gstatic.com/s/outfit/v15/QGYyz_MVcBeNP4NjuGObqx1XmO1I4deyC4E.ttf' -OutFile (Join-Path $fonts 'outfit-700.ttf')
  Invoke-WebRequest -Uri 'https://fonts.gstatic.com/s/outfit/v15/QGYyz_MVcBeNP4NjuGObqx1XmO1I4bCyC4E.ttf' -OutFile (Join-Path $fonts 'outfit-800.ttf')

  $index = Get-Content -LiteralPath (Join-Path $clone 'index.html') -Raw
  $index = $index -replace '(?ms)\s*<link rel="preconnect" href="https://fonts\.googleapis\.com" />', ''
  $index = $index -replace '(?ms)\s*<link rel="preconnect" href="https://fonts\.gstatic\.com" crossorigin />', ''
  $index = $index -replace '(?ms)\s*<link\s+href="https://fonts\.googleapis\.com/css2\?family=Outfit:wght@500;700;800&display=swap"\s+rel="stylesheet"\s*/>', ''
  $index = $index -replace '(?ms)\s*<link rel="preconnect" href="https://esm\.sh" />', ''
  $index = $index -replace '(?ms)\s*<link rel="stylesheet" href="https://esm\.sh/solid-glass@0\.0\.3/css" />', ''
  $index = $index.Replace('href="./favicon.ico"', 'href="./src/assets/favicon.ico"')
  $index = $index -replace '(?m)^\s*<link rel="stylesheet" href="\./static/css/style\.css" />\r?\n?', ''
  $index = $index.Replace('src="./static/js/app.js"', 'src="./src/js/app.js"')
  Set-Content -LiteralPath (Join-Path $root 'index.html') -Value $index -NoNewline

  $app = Join-Path $src 'js\app.js'
  Replace-Text $app "import { createLiquidGlass } from 'https://esm.sh/solid-glass@0.0.3/engines/svg-refraction';" "import 'solid-glass/css';`nimport { createLiquidGlass } from 'solid-glass/engines/svg-refraction';"
  Replace-Text $app "import { zip } from 'https://esm.sh/fflate@0.8.2';" "import { zipSync } from 'fflate';`nimport '../css/style.css';"
  Replace-Text $app "downloadBlob(new Blob([file.bytes], { type: file.mime }), file.name);" "const saved = await downloadBlob(`n        new Blob([file.bytes], { type: file.mime }),`n        file.name,`n      );`n      if (!saved) {`n        showToast('Download canceled.');`n        return;`n      }"
  Replace-Text $app "downloadBlob(`n        new Blob([zipBytes], { type: 'application/zip' }),`n        'picdrop-images.zip',`n      );" "const saved = await downloadBlob(`n        new Blob([zipBytes], { type: 'application/zip' }),`n        'picdrop-images.zip',`n      );`n      if (!saved) {`n        showToast('Download canceled.');`n        return;`n      }"
  Replace-Text $app "showToast('Compressing files...', { persist: true });" "showToast('Preparing ZIP file...', { persist: true });"
  Replace-Text $app @'
      const zipBytes = await new Promise((resolve, reject) => {
        zip(zipEntries, { level: 6 }, (err, data) => {
          if (err) reject(err);
          else resolve(data);
        });
      });
'@ @'
      const zipBytes = zipSync(zipEntries, { level: 0 });
'@

  Apply-TauriDownloadPatch (Join-Path $src 'js\modules\file-utils.js')

  $css = Join-Path $src 'css\style.css'
  $cssContent = Get-Content -LiteralPath $css -Raw
  $fontFace = @"
@font-face {
  font-family: 'Outfit';
  font-style: normal;
  font-weight: 500;
  font-display: swap;
  src: url('../assets/fonts/outfit-500.ttf') format('truetype');
}

@font-face {
  font-family: 'Outfit';
  font-style: normal;
  font-weight: 700;
  font-display: swap;
  src: url('../assets/fonts/outfit-700.ttf') format('truetype');
}

@font-face {
  font-family: 'Outfit';
  font-style: normal;
  font-weight: 800;
  font-display: swap;
  src: url('../assets/fonts/outfit-800.ttf') format('truetype');
}

"@
  $cssContent = $fontFace + $cssContent.Replace("url('../images/backgrounds/1.jpg')", "url('../assets/images/backgrounds/1.jpg')")
  Set-Content -LiteralPath $css -Value $cssContent -NoNewline

  $effects = Join-Path $src 'js\modules\ui-effects.js'
  $effectsContent = Get-Content -LiteralPath $effects -Raw
  $backgroundLines = 1..10 | ForEach-Object {
    "  new URL('../../assets/images/backgrounds/$_.jpg', import.meta.url).href,"
  }
  $replacement = "const BACKGROUNDS = Object.freeze([`n$($backgroundLines -join "`n")`n]);"
  $effectsContent = $effectsContent -replace '(?ms)const BACKGROUNDS = Object\.freeze\(\[\s*.*?\s*\]\);', $replacement
  Set-Content -LiteralPath $effects -Value $effectsContent -NoNewline

  $head = git -C $clone rev-parse HEAD
  Write-Output "Synced PicDrop GitHub Page source from $repoUrl@$head into src."
}
finally {
  Remove-PathIfExists $tmp
}
