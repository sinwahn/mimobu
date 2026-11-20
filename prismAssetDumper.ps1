<#
.SYNOPSIS
Adds every mod and resource pack installed in your Prism Launcher instances to
assets.yaml. Entries already in assets.yaml are kept as they are.

.EXAMPLE
.\prismAssetDumper.ps1
.\prismAssetDumper.ps1 -InstancesDir 'D:\PrismLauncher\instances'
#>
[CmdletBinding()]
param(
	# By default the repo is expected inside the Prism Launcher folder.
	[string]$InstancesDir = (Join-Path $PSScriptRoot '../instances'),
	[string]$AssetsFile = (Join-Path $PSScriptRoot 'assets.yaml')
)

$ErrorActionPreference = 'Stop'
foreach ($part in 'Common', 'Config', 'Catalog') {
	. (Join-Path $PSScriptRoot "src/$part.ps1")
}

function ConvertFrom-TomlString([string]$Raw) {
	$value = $Raw.Trim()
	if ($value -match "^'(.*)'$") { return $Matches[1] }
	if ($value -match '^"(.*)"$') { return ($Matches[1] -replace '\\"', '"' -replace '\\\\', '\') }
	return $value
}

# The flat "section.key" -> value pairs of a packwiz .pw.toml file, which is all
# Prism writes there.
function Read-PackwizFile([string]$Path) {
	$values = @{}
	$section = ''
	foreach ($line in [IO.File]::ReadAllLines($Path)) {
		$text = $line.Trim()
		if ($text -match '^\[(.+)\]$') {
			$section = $Matches[1].Trim()
		} elseif ($text -match '^([A-Za-z0-9_-]+)\s*=\s*(.+)$') {
			$name = if ($section) { "$section.$($Matches[1])" } else { $Matches[1] }
			$values[$name] = ConvertFrom-TomlString $Matches[2]
		}
	}
	return $values
}

function ConvertTo-AssetEntry($Values) {
	if (-not $Values['name']) { return $null }
	$curseforge = $Values['update.curseforge.project-id']
	$modrinth = $Values['update.modrinth.mod-id']
	if ($curseforge) { return [ordered]@{ name = $Values['name']; source = 'curseforge'; mod_id = "$curseforge" } }
	if ($modrinth) { return [ordered]@{ name = $Values['name']; source = 'modrinth'; mod_id = "$modrinth" } }
	return $null
}

try {
	Import-YamlModule
	$instancesRoot = Get-FullPath $InstancesDir
	if (-not (Test-Path -LiteralPath $instancesRoot)) { throw "Instances folder not found: $instancesRoot (pass -InstancesDir)" }

	$assets = if (Test-Path -LiteralPath (Get-FullPath $AssetsFile)) { Read-YamlFile $AssetsFile } else { @{} }
	foreach ($kind in $script:AssetKinds) {
		if ($null -eq (Get-MapValue $assets $kind)) { $assets[$kind] = @{} }
	}

	$added = @{ mods = 0; resourcepacks = 0 }
	foreach ($instance in Get-ChildItem -LiteralPath $instancesRoot -Directory) {
		foreach ($kind in $script:AssetKinds) {
			$indexDir = Join-Path $instance.FullName "minecraft/$kind/.index"
			if (-not (Test-Path -LiteralPath $indexDir)) { continue }
			foreach ($file in Get-ChildItem -LiteralPath $indexDir -Filter '*.pw.toml') {
				$entry = ConvertTo-AssetEntry (Read-PackwizFile $file.FullName)
				if ($null -eq $entry) {
					Write-Verbose "no name or site id in $($file.FullName)"
					continue
				}
				$key = ConvertTo-AssetKey $entry.name
				if ($assets[$kind].Contains($key)) { continue }
				$assets[$kind][$key] = $entry
				$added[$kind]++
				Write-Info "+ $kind/$key ($($instance.Name))" Green
			}
		}
	}

	if ($added.mods + $added.resourcepacks -eq 0) {
		Write-Info 'Nothing new; assets.yaml already lists everything installed.'
		return
	}
	Save-AssetCatalog $assets $AssetsFile
	Write-Info "Added $($added.mods) mods and $($added.resourcepacks) resource packs to assets.yaml (previous version kept as assets.yaml.bak)" White
} catch {
	Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
	exit 1
}
