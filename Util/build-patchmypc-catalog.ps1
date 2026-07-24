<#
.SYNOPSIS
  Builds a slim patchmypc-catalog.json from Patch My PC's full PatchMyPC.xml
  SCUP/WSUS catalog export, for the Intune compliance report page to load
  instead of parsing the full ~16 MB XML file in the browser.

.DESCRIPTION
  Mirrors the parsing/grouping logic in intune-signin.html's client-side
  JS (parseTitle, extractArch, matcherReferencesArch, extractDisplayName
  Groups, parsePatchMyPcCatalog) so the two stay in sync. If you change how
  products are parsed/grouped in intune-signin.html, make the equivalent
  change here too.

  Re-run this script whenever PatchMyPC.xml is updated/replaced:
    .\build-patchmypc-catalog.ps1

.NOTES
  Output: patchmypc-catalog.json — an array of
    { id, name, vendor, latestVersion, matchers: [ [ { comparison, data } ] ] }
  where each entry in `matchers` is an AND-combined group of DisplayName
  conditions (all conditions in a group must match); different groups are
  OR alternatives.
#>

param(
  [string]$InputPath = (Join-Path $PSScriptRoot "PatchMyPC.xml"),
  [string]$OutputPath = (Join-Path $PSScriptRoot "patchmypc-catalog.json")
)

if (-not (Test-Path $InputPath)) {
  throw "Could not find $InputPath"
}

Write-Host "Loading $InputPath ..."
[xml]$xml = Get-Content $InputPath -Raw
$ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
# Local-name-only matching (ignore namespace prefixes), same approach as
# the browser's findAllByLocalName/findFirstByLocalName helpers.
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

# Splits a title like "Microsoft OneDrive 26.113.0614.0004 (x64)" into
# name/version/suffix. Mirrors parseTitle() in intune-signin.html.
function Parse-Title([string]$Title) {
  $suffix = $null
  if ($Title -match '\(([^)]*)\)\s*$') { $suffix = $Matches[1] }
  $s = $Title -replace '\s*\([^)]*\)\s*$', ''
  $s = $s -replace '\s+Rev\d+$', ''
  $tokens = $s -split '\s+'
  $versionIdx = -1
  for ($i = $tokens.Count - 1; $i -ge 0; $i--) {
    if ($tokens[$i] -match '^\d+(\.\d+){1,4}$') { $versionIdx = $i; break }
  }
  if ($versionIdx -eq -1) {
    return @{ Name = $s.Trim(); Version = $null; Suffix = $suffix }
  }
  $nameTokens = $tokens[0..($versionIdx - 1)]
  if ($nameTokens.Count -gt 0 -and $nameTokens[-1] -match '^latest$') {
    $nameTokens = $nameTokens[0..($nameTokens.Count - 2)]
  }
  return @{ Name = ($nameTokens -join " ").Trim(); Version = $tokens[$versionIdx]; Suffix = $suffix }
}

# Mirrors extractArch(): pulls an x86/x64/x32/arm64 token out of the
# title's trailing installer-type suffix (e.g. "EXE-x64" -> "x64").
function Get-Arch([string]$Suffix) {
  if (-not $Suffix) { return $null }
  foreach ($token in ($Suffix -split '[^A-Za-z0-9]+')) {
    if ($token -match '^(x86|x64|x32|arm64)$') { return $token.ToLowerInvariant() }
  }
  return $null
}

# Recursively evaluates a subtree for its DisplayName-matching semantics,
# returning a list of "alternative" condition groups: each group is a
# list of {comparison, data} conditions that must ALL be true (AND); the
# groups themselves are OR alternatives (any one group matching is
# enough). This correctly distributes AND over OR (e.g. an <lar:And>
# containing an <lar:Or> produces one alternative group per Or branch,
# each still combined with the And's other conditions) instead of
# flattening everything into a single AND group regardless of nesting.
#
# IMPORTANT: the return value is always wrapped in a single-property
# [PSCustomObject] (`.Items`), never a bare array/List. PowerShell's
# pipeline/`return` auto-enumerates and silently flattens nested
# collections (a List[object] of List[object] can come back one level
# too flat, or fully collapsed, depending on element counts) — wrapping
# in a scalar object sidesteps that entirely, since PSCustomObject isn't
# itself enumerable. An earlier version of this function returned bare
# nested arrays/lists directly and, despite looking correct in isolated
# tests, silently collapsed to near-empty results across the full
# recursion depth of real package rules (regenerating almost no
# products). Do not "simplify" this back to bare array returns without
# re-testing against the full PatchMyPC.xml (expect ~2247 products).
#
# - RegSz (Value=DisplayName): one alternative, a single-condition group.
# - Any other leaf element (RegSzToVersion, RegDword, WindowsVersion,
#   etc.): contributes no DisplayName info, i.e. the identity element
#   (one alternative with an empty condition list) so it doesn't affect
#   AND-combination with its siblings.
# - Not: dropped entirely (see rationale below) — also the identity
#   element.
# - Or: the union of its children's alternatives (OR).
# - And / RegKeyLoop: the cross-product of its children's alternatives,
#   concatenating conditions within each combination (AND).
function Get-DisplayNameAlternatives([System.Xml.XmlNode]$Node) {
  switch ($Node.LocalName) {
    "RegSz" {
      $alternatives = [System.Collections.Generic.List[object]]::new()
      if ($Node.Value -eq "DisplayName" -and $Node.Data) {
        $group = [System.Collections.Generic.List[object]]::new()
        $group.Add([PSCustomObject]@{ comparison = $Node.Comparison; data = $Node.Data })
        $alternatives.Add($group)
      } else {
        $alternatives.Add([System.Collections.Generic.List[object]]::new())
      }
      return [PSCustomObject]@{ Items = $alternatives }
    }
    "Not" {
      # DisplayName conditions nested inside <lar:Not> are exclusions
      # (e.g. "Bria" AND NOT "Bria Enterprise", to keep the Enterprise
      # SKU's own product from also matching plain "Bria"). Since
      # EqualTo/BeginsWith/etc. conditions can never simultaneously equal
      # two different strings, a negated DisplayName check never actually
      # changes whether an unrelated positive check matches — so these
      # are dropped entirely (identity) rather than folded in as
      # impossible positive requirements.
      $alternatives = [System.Collections.Generic.List[object]]::new()
      $alternatives.Add([System.Collections.Generic.List[object]]::new())
      return [PSCustomObject]@{ Items = $alternatives }
    }
    "Or" {
      $alternatives = [System.Collections.Generic.List[object]]::new()
      foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $childResult = Get-DisplayNameAlternatives $child
        foreach ($alt in $childResult.Items) { $alternatives.Add($alt) }
      }
      if ($alternatives.Count -eq 0) { $alternatives.Add([System.Collections.Generic.List[object]]::new()) }
      return [PSCustomObject]@{ Items = $alternatives }
    }
    default {
      # And, RegKeyLoop, or anything else with children: AND-combine via
      # cross-product so nested Or branches are distributed correctly
      # instead of flattened away.
      $accumulated = [System.Collections.Generic.List[object]]::new()
      $accumulated.Add([System.Collections.Generic.List[object]]::new()) # identity: one empty alternative
      foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        $childResult = Get-DisplayNameAlternatives $child
        $combined = [System.Collections.Generic.List[object]]::new()
        foreach ($existing in $accumulated) {
          foreach ($alt in $childResult.Items) {
            $newGroup = [System.Collections.Generic.List[object]]::new()
            $newGroup.AddRange($existing)
            $newGroup.AddRange($alt)
            $combined.Add($newGroup)
          }
        }
        $accumulated = $combined
      }
      return [PSCustomObject]@{ Items = $accumulated }
    }
  }
}

# Mirrors extractDisplayNameGroups(): builds matcher groups per
# RegKeyLoop by evaluating its And/Or/Not structure (via
# Get-DisplayNameAlternatives) instead of flattening every DisplayName
# condition in the loop into one AND group. Patch My PC rules commonly
# wrap alternative DisplayName spellings (e.g. "Notepad++" vs
# "Notepad++ (x64)", or "Miro" vs "Miro X.Y.Z") in a <lar:Or> — sometimes
# with one branch itself being an <lar:And> of multiple conditions (e.g.
# "BeginsWith 'Miro ' AND Contains '.'"). Flattening ignored that nesting
# and either produced impossible AND groups (conditions that can never
# both be true, silently hiding the product) or, if the Or branches were
# split without preserving their internal And-grouping, overly broad
# standalone conditions (e.g. a lone "Contains '.'" matching almost any
# app with a version number in its name, wrongly attributing unrelated
# installs to this product).
function Get-DisplayNameGroups([System.Xml.XmlNode]$Package) {
  $groups = [System.Collections.Generic.List[object]]::new()
  foreach ($loop in (Get-ByLocalName $Package "RegKeyLoop")) {
    $result = Get-DisplayNameAlternatives $loop
    foreach ($alternative in $result.Items) {
      if ($alternative.Count -gt 0) { $groups.Add($alternative) }
    }
  }
  return [PSCustomObject]@{ Items = $groups }
}

# Mirrors matcherReferencesArch(): true if any DisplayName condition
# explicitly mentions the given architecture as a whole word.
function Test-MatcherReferencesArch($Groups, [string]$Arch) {
  $pattern = "\b$Arch\b"
  foreach ($group in $Groups) {
    foreach ($condition in $group) {
      if ($condition.data -match $pattern) { return $true }
    }
  }
  return $false
}

# Mirrors guessVendor(): best-effort vendor label from the support/info URL.
function Get-GuessedVendor([string]$Url) {
  if (-not $Url) { return "" }
  try {
    $host_ = ([Uri]$Url).Host -replace '^www\.', ''
    $parts = $host_.Split(".")
    $label = if ($parts.Count -ge 2) { $parts[$parts.Count - 2] } else { $parts[0] }
    return $label.Substring(0,1).ToUpperInvariant() + $label.Substring(1)
  } catch {
    return ""
  }
}

$packages = Get-ByLocalName $xml "SoftwareDistributionPackage"
Write-Host "Found $($packages.Count) packages. Parsing..."

$productsByKey = [ordered]@{}

foreach ($pkg in $packages) {
  $titleEl = Get-FirstByLocalName $pkg "Title"
  if (-not $titleEl -or -not $titleEl.InnerText.Trim()) { continue }

  $parsed = Parse-Title $titleEl.InnerText.Trim()
  if (-not $parsed.Name) { continue }

  $groups = (Get-DisplayNameGroups $pkg).Items
  if ($groups.Count -eq 0) { continue } # no way to match installed apps to this package

  $arch = Get-Arch $parsed.Suffix
  $splitByArch = $arch -and (Test-MatcherReferencesArch $groups $arch)
  $displayName = if ($splitByArch) { "$($parsed.Name) ($arch)" } else { $parsed.Name }
  $key = $displayName.ToLowerInvariant()

  if (-not $productsByKey.Contains($key)) {
    $infoUrlEl = Get-FirstByLocalName $pkg "SupportUrl"
    if (-not $infoUrlEl) { $infoUrlEl = Get-FirstByLocalName $pkg "MoreInfoUrl" }
    $productsByKey[$key] = [PSCustomObject]@{
      id            = $key
      name          = $displayName
      vendor        = Get-GuessedVendor ($(if ($infoUrlEl) { $infoUrlEl.InnerText.Trim() } else { "" }))
      latestVersion = $null
      matchers      = [System.Collections.ArrayList]::new()
      _sigs         = [System.Collections.Generic.HashSet[string]]::new()
    }
  }
  $product = $productsByKey[$key]

  foreach ($group in $groups) {
    $sig = ($group | ForEach-Object { "$($_.comparison):$($_.data.ToLowerInvariant())" } | Sort-Object) -join "|"
    if (-not $product._sigs.Contains($sig)) {
      [void]$product._sigs.Add($sig)
      [void]$product.matchers.Add($group)
    }
  }

  if ((Compare-Versions $parsed.Version $product.latestVersion) -gt 0) {
    $product.latestVersion = $parsed.Version
  }
}

$catalog = $productsByKey.Values | ForEach-Object {
  [PSCustomObject]@{
    id            = $_.id
    name          = $_.name
    vendor        = $_.vendor
    latestVersion = $_.latestVersion
    matchers      = $_.matchers
  }
}

Write-Host "Writing $($catalog.Count) products to $OutputPath ..."
$catalog | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $OutputPath -Encoding utf8

$rawSize = (Get-Item $InputPath).Length
$outSize = (Get-Item $OutputPath).Length
Write-Host ("Done. {0:N1} MB -> {1:N1} KB ({2}% of original)." -f ($rawSize/1MB), ($outSize/1KB), [Math]::Round(100.0*$outSize/$rawSize,1))
