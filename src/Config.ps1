# Loading build.yaml, modules.yaml and assets.yaml into one build context.

$script:AssetKinds = @('mods', 'resourcepacks')

# The loader whose files are looked up. NeoForge did not exist before 1.20, and
# on 1.20.1 NeoForge still loads Forge mods, whose Forge tags are the reliable ones.
function Get-EffectiveLoader([string]$Loader, [string]$GameVersion) {
	$loader = $Loader.ToLower()
	if ($loader -ne 'neoforge' -or $GameVersion -notmatch '^1\.(\d+)') { return $loader }
	$minor = [int]$Matches[1]
	if ($minor -le 19 -or $GameVersion -eq '1.20.1') { return 'forge' }
	return $loader
}

# The CurseForge key from, in order: the CURSEFORGE_API_KEY environment variable,
# a curseforge.key file next to build.yaml, or the cf_api_key field of build.yaml.
function Get-CurseForgeKey([string]$BuildFile, $BuildData) {
	if ($env:CURSEFORGE_API_KEY) {
		return @{ Value = $env:CURSEFORGE_API_KEY.Trim(); From = 'CURSEFORGE_API_KEY' }
	}
	$keyFile = Join-Path (Split-Path -Parent (Get-FullPath $BuildFile)) 'curseforge.key'
	if (Test-Path -LiteralPath $keyFile) {
		$value = ([IO.File]::ReadAllText($keyFile)).Trim()
		if ($value) { return @{ Value = $value; From = 'curseforge.key' } }
	}
	$legacy = Get-MapValue $BuildData 'cf_api_key'
	if ($legacy) { return @{ Value = "$legacy".Trim(); From = 'build.yaml' } }
	return $null
}

# alias -> module name, from the optional "aliases" list of each module.
function Get-ModuleAliases($ModulesData) {
	$aliases = @{}
	foreach ($section in 'main_modules', 'sub_modules') {
		$modules = Get-MapValue $ModulesData $section
		if ($null -eq $modules) { continue }
		foreach ($name in $modules.Keys) {
			foreach ($alias in @(Get-Items (Get-MapValue $modules[$name] 'aliases'))) {
				$aliases["$alias"] = $name
			}
		}
	}
	return $aliases
}

function New-BuildContext {
	param(
		[string]$BuildFile,
		[string]$ModulesFile,
		[string]$AssetsFile
	)
	$build = Read-YamlFile $BuildFile
	$modules = Read-YamlFile $ModulesFile
	$assets = Read-YamlFile $AssetsFile

	if (-not $build.version) { throw "$BuildFile has no 'version'" }
	if ($build.version -isnot [string]) {
		# YAML reads 1.20 as the number 1.2
		throw "$BuildFile`: write the version in quotes, for example version: `"$($build.version)`""
	}
	if (-not $build.modloader) { throw "$BuildFile has no 'modloader'" }
	foreach ($kind in $script:AssetKinds) {
		if ($null -eq (Get-MapValue $assets $kind)) { $assets[$kind] = @{} }
	}

	$selection = @{}
	foreach ($kind in $script:AssetKinds) { $selection[$kind] = [ordered]@{} }

	return @{
		GameVersion       = "$($build.version)"
		RequestedLoader   = "$($build.modloader)".ToLower()
		Loader            = Get-EffectiveLoader "$($build.modloader)" "$($build.version)"
		AllowIntegrations = [bool]$build.allow_integrations
		Build             = $build
		Modules           = $modules
		ModuleAliases     = Get-ModuleAliases $modules
		Assets            = $assets
		AssetsFile        = $AssetsFile
		CurseForge        = Get-CurseForgeKey $BuildFile $build
		Releases          = @{}       # "kind::key" or "kind::key::latest" -> release
		AssetIndex        = $null     # "source::id" -> mod key, built on first use
		Selection         = $selection # kind -> ordered key -> @{ Via; Pinned; Release }
		ActiveModules     = New-Object 'System.Collections.Generic.HashSet[string]'
		Skipped           = New-Object 'System.Collections.Generic.List[object]'
		Problems          = New-Object 'System.Collections.Generic.List[string]'
		Discovered        = [ordered]@{} # mod key -> entry found through dependencies
	}
}

# Something the user should look at; shown in the summary.
function Add-Problem($Ctx, [string]$Text) {
	if (-not $Ctx.Problems.Contains($Text)) { $Ctx.Problems.Add($Text) }
	Write-Verbose "problem: $Text"
}

# An asset that was asked for but not taken. Failed means the lookup itself broke
# (network, API), as opposed to the asset having no fitting version.
function Add-Skip($Ctx, [string]$Kind, [string]$Key, [string]$Reason, [string]$Via, [bool]$Failed = $false) {
	$Ctx.Skipped.Add(@{ Kind = $Kind; Key = $Key; Reason = $Reason; Via = $Via; Failed = $Failed })
	Write-Verbose "skip $Kind/$Key ($Via): $Reason"
}
