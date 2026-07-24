<#
.SYNOPSIS
  Builds a slim patchmypc-catalog.json for the Intune compliance report page,
  from Patch My PC's official SupportedProducts.xml (the "is this app one we
  support" list) plus PatchMyPC.xml (the SCUP/WSUS catalog export, used only
  for version numbers).

.DESCRIPTION
  Previous versions of this script tried to determine both "is this app
  supported" AND "what's the latest version" purely from PatchMyPC.xml's
  applicability rules (nested <lar:And>/<lar:Or>/<lar:Not> around
  <bar:RegSz Value="DisplayName"> conditions). That XML is meant for
  install/upgrade detection, not reporting, is undocumented, and reverse
  engineering it caused several rounds of matcher bugs (impossible AND
  groups, overly-broad standalone conditions from mis-handled nested
  And-inside-Or, etc.).

  Patch My PC publishes a purpose-built feed for exactly this "compare
  inventory against supported products" scenario:
  https://api.patchmypc.com/downloads/xml/supportedproducts.xml — the same
  feed their own community script (Get-PMPCFoundApps.ps1) uses. Each
  <Product> has simple SQL-LIKE-style name patterns (SQLSearchInclude /
  SQLSearchExclude / Exclude, using % and _ wildcards) instead of a nested
  rule tree, so this script now uses THAT as the source of truth for
  "is this app supported" (mirrored client-side in intune-signin.html via
  likeToRegex/matchesLike/matchCatalogProduct — keep both in sync).

  PatchMyPC.xml is now used ONLY to look up a "latest version" per product,
  by matching each WSUS package's parsed <sdp:Title> name against the same
  Include/Exclude LIKE patterns used for detection (no applicability-rule
  parsing needed at all anymore).

  NOTE: api.patchmypc.com does not send CORS headers, so the browser can't
  fetch SupportedProducts.xml directly — that's why this pre-processing
  step is still needed. The resulting patchmypc-catalog.json is written
  straight into docs/ (default OutputPath) so it's published as a static
  file by GitHub Pages alongside index.html — same origin, no CORS setup,
  no separate upload step.

  Re-run this script whenever PatchMyPC.xml or SupportedProducts.xml is
  updated/replaced:
    .\build-patchmypc-catalog.ps1

.NOTES
  Output: docs/patchmypc-catalog.json — an array of
    { id, name, vendor, include, excludes: [ ... ], latestVersion, releaseDate }
  `include`/`excludes` are raw SQL-LIKE patterns (% = any chars, _ = any
  single char) — convert with the same likeToRegex() logic as
  intune-signin.html before matching against a detected app's DisplayName.
  `releaseDate` is the ISO 8601 CreationDate (from PatchMyPC.xml's
  <Properties> element) of the WSUS package that matched `latestVersion` —
  i.e. when Patch My PC published that version — or null if latestVersion
  is null.
#>

param(
  [string]$InputPath = (Join-Path $PSScriptRoot "PatchMyPC.xml"),
  [string]$SupportedProductsPath = (Join-Path $PSScriptRoot "supportedproducts.xml"),
  [string]$SupportedProductsUrl = "https://api.patchmypc.com/downloads/xml/supportedproducts.xml",
  [string]$OutputPath = (Join-Path $PSScriptRoot "..\docs\patchmypc-catalog.json"),
  [switch]$SkipDownload
)

if (-not (Test-Path $InputPath)) {
  throw "Could not find $InputPath"
}

if (-not $SkipDownload) {
  Write-Host "Downloading $SupportedProductsUrl ..."
  Invoke-WebRequest -Uri $SupportedProductsUrl -OutFile $SupportedProductsPath -UseBasicParsing
} elseif (-not (Test-Path $SupportedProductsPath)) {
  throw "Could not find $SupportedProductsPath (and -SkipDownload was specified)"
}

function Get-ByLocalName([System.Xml.XmlNode]$Root, [string]$LocalName) {
  $Root.SelectNodes(".//*[local-name()='$LocalName']")
}
function Get-FirstByLocalName([System.Xml.XmlNode]$Root, [string]$LocalName) {
  $Root.SelectSingleNode(".//*[local-name()='$LocalName']")
}

function ConvertTo-CompareParts([string]$Version) {
  if (-not $Version) { return @() }
  $Version.Split(".") | ForEach-Object { [int]($_ -as [int]) }
}
function Compare-Versions([string]$A, [string]$B) {
  if (-not $A) { if ($B) { return -1 } else { return 0 } }
  if (-not $B) { return 1 }
  $pa = ConvertTo-CompareParts $A
  $pb = ConvertTo-CompareParts $B
  $max = [Math]::Max($pa.Count, $pb.Count)
  for ($i = 0; $i -lt $max; $i++) {
    $va = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
    $vb = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
    if ($va -ne $vb) { return $va - $vb }
  }
  return 0
}

# Splits a title like "Microsoft OneDrive 26.113.0614.0004 (x64)" into just
# the product name (version/suffix are dropped — we only need the name here
# to match it against SupportedProducts.xml's Include/Exclude patterns).
# Mirrors parseTitle() in intune-signin.html.
function Parse-TitleName([string]$Title) {
  $s = $Title -replace '\s*\([^)]*\)\s*$', ''
  $s = $s -replace '\s+Rev\d+$', ''
  $tokens = $s -split '\s+'
  for ($i = $tokens.Count - 1; $i -ge 0; $i--) {
    if ($tokens[$i] -match '^\d+(\.\d+){1,4}$') {
      $nameTokens = if ($i -gt 0) { $tokens[0..($i - 1)] } else { @() }
      if ($nameTokens.Count -gt 0 -and $nameTokens[-1] -match '^latest$') {
        $nameTokens = if ($nameTokens.Count -gt 1) { $nameTokens[0..($nameTokens.Count - 2)] } else { @() }
      }
      return ($nameTokens -join " ").Trim()
    }
  }
  return $s.Trim()
}
function Parse-TitleVersion([string]$Title) {
  $s = $Title -replace '\s*\([^)]*\)\s*$', ''
  $s = $s -replace '\s+Rev\d+$', ''
  $tokens = $s -split '\s+'
  for ($i = $tokens.Count - 1; $i -ge 0; $i--) {
    if ($tokens[$i] -match '^\d+(\.\d+){1,4}$') { return $tokens[$i] }
  }
  return $null
}

# Pulls an x86/x64/x32/arm64 token out of a trailing "(...)" suffix, e.g.
# "(EXE-x64)" -> "x64", "(64-bit x64)" -> "x64". Used as a fallback join
# key between PatchMyPC.xml's WSUS package titles and SupportedProducts.
# xml's product names, since both commonly (but not always — see
# Include/SQLSearchInclude, which target the real installed DisplayName
# text instead) use this short "(...arch...)" suffix convention.
function Get-ArchSuffix([string]$Title) {
  if ($Title -notmatch '\(([^)]*)\)\s*$') { return $null }
  foreach ($token in ($Matches[1] -split '[^A-Za-z0-9]+')) {
    if ($token -match '^(x86|x64|x32|arm64)$') { return $token.ToLowerInvariant() }
  }
  return $null
}

# Converts a SQL LIKE pattern (% = any run of chars, _ = any single char)
# into an anchored, case-insensitive regex. Mirrors likeToRegex() in
# intune-signin.html — keep both in sync.
function Convert-LikeToRegex([string]$Pattern) {
  $escaped = [regex]::Escape($Pattern.Trim())
  $escaped = $escaped -replace '%', '.*' -replace '_', '.'
  return New-Object System.Text.RegularExpressions.Regex("^$escaped`$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

Write-Host "Loading $InputPath ..."
[xml]$wsusXml = Get-Content $InputPath -Raw
$titleNodes = Get-ByLocalName $wsusXml "Title"
Write-Host "Found $($titleNodes.Count) WSUS package titles. Parsing names/versions..."

# name -> highest version seen for that parsed name (deduped so the
# per-product version scan below doesn't repeat work for identical names).
# Also keyed by (name, arch) for the fallback matching pass below.
$wsusVersionsByName = [ordered]@{}
$wsusVersionsByNameArch = [ordered]@{}
foreach ($titleEl in $titleNodes) {
  $title = $titleEl.InnerText.Trim()
  if (-not $title) { continue }
  $name = Parse-TitleName $title
  if (-not $name) { continue }
  $version = Parse-TitleVersion $title
  $arch = Get-ArchSuffix $title

  # CreationDate lives on the ancestor package's <Properties> element —
  # this is when Patch My PC published this specific package/version,
  # which we surface in the report as each product's "release date".
  $pkg = $titleEl.ParentNode.ParentNode
  $props = $pkg.SelectSingleNode("*[local-name()='Properties']")
  $releaseDate = if ($props -and $props.CreationDate) { $props.CreationDate } else { $null }

  $key = $name.ToLowerInvariant()
  if (-not $wsusVersionsByName.Contains($key)) {
    $wsusVersionsByName[$key] = [PSCustomObject]@{ Name = $name; Version = $version; ReleaseDate = $releaseDate }
  } elseif ((Compare-Versions $version $wsusVersionsByName[$key].Version) -gt 0) {
    $wsusVersionsByName[$key].Version = $version
    $wsusVersionsByName[$key].ReleaseDate = $releaseDate
  }

  $archKey = "$key|$arch"
  if (-not $wsusVersionsByNameArch.Contains($archKey)) {
    $wsusVersionsByNameArch[$archKey] = [PSCustomObject]@{ Version = $version; ReleaseDate = $releaseDate }
  } elseif ((Compare-Versions $version $wsusVersionsByNameArch[$archKey].Version) -gt 0) {
    $wsusVersionsByNameArch[$archKey].Version = $version
    $wsusVersionsByNameArch[$archKey].ReleaseDate = $releaseDate
  }
}
$wsusEntries = $wsusVersionsByName.Values
Write-Host "Found $($wsusEntries.Count) unique WSUS package names."

Write-Host "Loading $SupportedProductsPath ..."
[xml]$spXml = Get-Content $SupportedProductsPath -Raw
$catalog = [System.Collections.Generic.List[object]]::new()

foreach ($vendor in $spXml.SupportedProducts.Vendor) {
  foreach ($product in $vendor.Product) {
    # Products with a <ProductSplit> are a generic "parent" entry replaced
    # by separate arch-specific <Product> children (which do have their
    # own id/vendorid) — skip the parent to avoid double-counting, same as
    # Patch My PC's own Get-PMPCFoundApps.ps1 community script does.
    if ($product.ProductSplit) { continue }
    if (-not $product.SQLSearchInclude -or [string]::IsNullOrWhiteSpace($product.SQLSearchInclude)) { continue }

    $includePattern = $product.SQLSearchInclude.Trim()
    $excludes = @($product.SQLSearchExclude, $product.Exclude) |
      Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.Trim() }

    $catalog.Add([PSCustomObject]@{
        id            = $product.id
        name          = $product.Name
        vendor        = $vendor.name
        include       = $includePattern
        excludes      = @($excludes)
        latestVersion = $null
        releaseDate   = $null
      })
  }
}
Write-Host "Found $($catalog.Count) supported products (after skipping ProductSplit parents / products with no SQLSearchInclude)."

Write-Host "Matching WSUS package names against each product's Include/Exclude patterns for version info..."
$matchedCount = 0
foreach ($product in $catalog) {
  $includeRx = Convert-LikeToRegex $product.include
  $excludeRxs = $product.excludes | ForEach-Object { Convert-LikeToRegex $_ }

  $latest = $null
  $latestReleaseDate = $null
  foreach ($entry in $wsusEntries) {
    if (-not $includeRx.IsMatch($entry.Name)) { continue }
    $excluded = $false
    foreach ($rx in $excludeRxs) {
      if ($rx.IsMatch($entry.Name)) { $excluded = $true; break }
    }
    if ($excluded) { continue }
    if ((Compare-Versions $entry.Version $latest) -gt 0) {
      $latest = $entry.Version
      $latestReleaseDate = $entry.ReleaseDate
    }
  }
  if ($latest) {
    $product.latestVersion = $latest
    $product.releaseDate = $latestReleaseDate
    $matchedCount++
  }
}
Write-Host "Found a latest version for $matchedCount of $($catalog.Count) products via Include/Exclude pattern matching."

# Fallback pass: Include/SQLSearchInclude patterns target the real
# installed-app DisplayName text (e.g. "Notepad++ (64-bit x64)"), which
# for many products differs from PatchMyPC.xml's WSUS package title
# suffix convention (e.g. "Notepad++ 8.9.7.0 (x64)") — so the pass above
# can miss arch-specific products. As a fallback, also try matching by
# the product's own Name (stripped of its trailing "(...)" suffix) plus
# that suffix's arch token, since both feeds commonly (not always) use
# the same short "(...arch...)" suffix convention for that.
$fallbackMatchedCount = 0
foreach ($product in $catalog) {
  if ($product.latestVersion) { continue }
  $baseName = Parse-TitleName $product.name
  if (-not $baseName) { continue }
  $arch = Get-ArchSuffix $product.name
  $key = $baseName.ToLowerInvariant()

  $entry = $wsusVersionsByNameArch["$key|$arch"]
  if (-not $entry -and $arch) {
    # No exact arch-specific WSUS entry — try the arch-less bucket too,
    # in case this product isn't actually split by architecture upstream.
    $entry = $wsusVersionsByNameArch["$key|"]
  }
  if ($entry -and $entry.Version) {
    $product.latestVersion = $entry.Version
    $product.releaseDate = $entry.ReleaseDate
    $fallbackMatchedCount++
  }
}
Write-Host "Found a latest version for $fallbackMatchedCount more products via the name/arch fallback ($($matchedCount + $fallbackMatchedCount) of $($catalog.Count) total)."

# Drop the helper-only fields before serializing (none currently, but keep
# this here in case future fields need excluding).
$output = $catalog | ForEach-Object {
  [PSCustomObject]@{
    id            = $_.id
    name          = $_.name
    vendor        = $_.vendor
    include       = $_.include
    excludes      = $_.excludes
    latestVersion = $_.latestVersion
    releaseDate   = $_.releaseDate
  }
}

Write-Host "Writing $($output.Count) products to $OutputPath ..."
$output | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $OutputPath -Encoding utf8 -NoNewline

$rawSize = (Get-Item $InputPath).Length + (Get-Item $SupportedProductsPath).Length
$outSize = (Get-Item $OutputPath).Length
Write-Host ("Done. {0:N1} MB -> {1:N1} KB ({2}% of original)." -f ($rawSize/1MB), ($outSize/1KB), [Math]::Round(100.0*$outSize/$rawSize,1))
