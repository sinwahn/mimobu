# Which file an asset resolves to. Every asset is looked up once per run; the
# answer carries the download, its hash and its dependencies.

# File: @{ Url; FileName; Sha1; Page; Note } or $null when nothing fits.
# Failed: the lookup broke (network, API, key) rather than finding no version.
function New-Release {
	param($File = $null, [bool]$Exact = $true, $Dependencies = @(), [string]$Reason = '', [bool]$Failed = $false)
	return @{ File = $File; Exact = $Exact; Dependencies = @($Dependencies); Reason = $Reason; Failed = $Failed }
}

function Get-NoMatchReason($Ctx, [string]$Kind, [bool]$MatchVersion) {
	if (-not $MatchVersion) { return 'no files at all' }
	if ($Kind -eq 'mods') { return "no version for $($Ctx.Loader) $($Ctx.GameVersion)" }
	return "no version for $($Ctx.GameVersion)"
}

function Find-SourceRelease($Ctx, [string]$Kind, $Asset, [bool]$MatchVersion) {
	try {
		switch ($Asset.source) {
			'modrinth' { return Find-ModrinthRelease $Ctx $Kind "$($Asset.mod_id)" $MatchVersion }
			'curseforge' { return Find-CurseForgeRelease $Ctx $Kind "$($Asset.mod_id)" $MatchVersion }
			default { return New-Release -Reason "unknown source '$($Asset.source)'" -Failed $true }
		}
	} catch {
		return New-Release -Reason $_.Exception.Message -Failed $true
	}
}

# A pinned asset that has no version for this build falls back to its newest file.
function Get-Release($Ctx, [string]$Kind, [string]$Key, [bool]$Pinned = $false) {
	$asset = $Ctx.Assets[$Kind][$Key]
	$exactKey = "$Kind::$Key"
	if (-not $Ctx.Releases.Contains($exactKey)) {
		Write-Progress -Activity 'Looking up files' -Status "$($Ctx.Releases.Count + 1): $Key"
		$Ctx.Releases[$exactKey] = Find-SourceRelease $Ctx $Kind $asset $true
	}
	$release = $Ctx.Releases[$exactKey]
	if ($null -ne $release.File -or -not $Pinned -or $release.Failed) { return $release }

	$latestKey = "$exactKey::latest"
	if (-not $Ctx.Releases.Contains($latestKey)) {
		$Ctx.Releases[$latestKey] = Find-SourceRelease $Ctx $Kind $asset $false
	}
	return $Ctx.Releases[$latestKey]
}

function Get-ProjectInfo($Ctx, [string]$Source, [string]$Id) {
	switch ($Source) {
		'modrinth' { return Get-ModrinthProjectInfo $Id }
		'curseforge' { return Get-CurseForgeModInfo $Ctx $Id }
	}
	return $null
}
