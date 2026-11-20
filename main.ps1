<#
.SYNOPSIS
Builds a modpack: picks mods and resource packs from the modules listed in
build.yaml, adds fitting integrations and required dependencies, and downloads
everything into the output folder.

.EXAMPLE
.\main.ps1
.\main.ps1 -DryRun            # show what would be downloaded, write nothing
.\main.ps1 -Verbose           # explain every decision
#>
[CmdletBinding()]
param(
	[string]$BuildFile = (Join-Path $PSScriptRoot 'build.yaml'),
	[string]$ModulesFile = (Join-Path $PSScriptRoot 'modules.yaml'),
	[string]$AssetsFile = (Join-Path $PSScriptRoot 'assets.yaml'),
	[string]$OutputDir = (Join-Path $PSScriptRoot 'output'),
	# Download every file again, even when an identical one is already there.
	[switch]$OverwriteExisting,
	# Resolve everything and report, but download, move and save nothing.
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'
foreach ($part in 'Common', 'Config', 'Releases', 'Modrinth', 'CurseForge', 'Catalog',
	'Selection', 'Dependencies', 'Download', 'Report') {
	. (Join-Path $PSScriptRoot "src/$part.ps1")
}

try {
	Initialize-Environment
	$ctx = New-BuildContext -BuildFile $BuildFile -ModulesFile $ModulesFile -AssetsFile $AssetsFile

	$loaderNote = if ($ctx.Loader -ne $ctx.RequestedLoader) { " ($($ctx.Loader) files)" } else { '' }
	Write-Step "Building $($ctx.GameVersion) $($ctx.RequestedLoader)$loaderNote into $(Get-FullPath $OutputDir)"
	if ($ctx.CurseForge) {
		Write-Info "CurseForge key from $($ctx.CurseForge.From)"
		if ($ctx.CurseForge.From -eq 'build.yaml') {
			Add-Problem $ctx 'the CurseForge key is in build.yaml; move it to CURSEFORGE_API_KEY or curseforge.key so it is never committed'
		}
	} else {
		Write-Info 'No CurseForge key: CurseForge assets will fail (see README)' Yellow
	}

	Write-Step 'Choosing mods'
	Select-Modules $ctx $ctx.Build.modules
	Add-Additions $ctx
	Add-Integrations $ctx
	Add-Dependencies $ctx
	Write-Progress -Activity 'Looking up files' -Completed
	Write-Info "$($ctx.ActiveModules.Count) modules, $($ctx.Selection.mods.Count) mods, $($ctx.Selection.resourcepacks.Count) resource packs"

	if ($ctx.Discovered.Count -gt 0) {
		$names = @($ctx.Discovered.Keys) -join ', '
		if ($DryRun) {
			Write-Info "Would add $($ctx.Discovered.Count) found dependencies to assets.yaml: $names" Magenta
		} else {
			Save-AssetCatalog $ctx.Assets $AssetsFile
			Write-Info "Added $($ctx.Discovered.Count) found dependencies to assets.yaml: $names" Magenta
		}
	}

	Write-Step $(if ($DryRun) { 'Checking files' } else { 'Downloading' })
	$files = Sync-Files $ctx $OutputDir $OverwriteExisting.IsPresent $DryRun.IsPresent
	Write-Summary $ctx $files $OutputDir $DryRun.IsPresent
} catch {
	Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
	Write-Verbose $_.ScriptStackTrace
	exit 1
}
