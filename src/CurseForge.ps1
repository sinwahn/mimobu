# CurseForge API: file lookup, mod info, and the Modrinth fallback for blocked files.

$script:CurseForgeApi = 'https://api.curseforge.com/v1'
$script:CurseForgeLoaderTypes = @{ forge = 1; fabric = 4; quilt = 5; neoforge = 6 }
$script:CurseForgeSha1 = 1

function Invoke-CurseForgeApi($Ctx, [string]$Path) {
	if ($null -eq $Ctx.CurseForge) {
		throw 'no CurseForge API key; set CURSEFORGE_API_KEY or create curseforge.key (see README)'
	}
	return Invoke-Api "$script:CurseForgeApi$Path" @{ 'x-api-key' = $Ctx.CurseForge.Value; Accept = 'application/json' }
}

function Get-CurseForgeModInfo($Ctx, [string]$ModId) {
	$mod = (Invoke-CurseForgeApi $Ctx "/mods/$ModId").data
	return @{
		Name   = $mod.name
		Slug   = $mod.slug
		Author = @($mod.authors)[0].name
		Page   = $mod.links.websiteUrl
	}
}

# The newest file of a mod for the build's game version (and loader, for mods).
# Files whose author forbids third-party downloads come without a URL: then the
# same project is looked up on Modrinth, and failing that the file is marked for
# manual download with its CurseForge page.
function Find-CurseForgeRelease($Ctx, [string]$Kind, [string]$ModId, [bool]$MatchVersion) {
	$query = @('pageSize=1')
	if ($MatchVersion) { $query += 'gameVersion=' + [uri]::EscapeDataString($Ctx.GameVersion) }
	if ($Kind -eq 'mods') {
		$loaderType = $script:CurseForgeLoaderTypes[$Ctx.Loader]
		if ($null -eq $loaderType) { return New-Release -Reason "CurseForge has no loader '$($Ctx.Loader)'" }
		$query += "modLoaderType=$loaderType"
	}

	$files = @((Invoke-CurseForgeApi $Ctx "/mods/$ModId/files?$($query -join '&')").data)
	if ($files.Count -eq 0) { return New-Release -Reason (Get-NoMatchReason $Ctx $Kind $MatchVersion) }

	$file = $files[0]
	$dependencies = foreach ($dep in @($file.dependencies)) {
		# relationType 3 = required, 2 = optional
		if ($dep.relationType -notin 2, 3) { continue }
		@{ Source = 'curseforge'; Id = "$($dep.modId)"; Required = ($dep.relationType -eq 3) }
	}
	$found = @{
		Url      = $file.downloadUrl
		FileName = $file.fileName
		Sha1     = @($file.hashes | Where-Object { $_.algo -eq $script:CurseForgeSha1 })[0].value
	}
	if (-not $found.Url) { $found = Find-BlockedFileSubstitute $Ctx $Kind $ModId $MatchVersion $found $file.id }
	return New-Release -Exact $MatchVersion -Dependencies @($dependencies) -File $found
}

function Find-BlockedFileSubstitute($Ctx, [string]$Kind, [string]$ModId, [bool]$MatchVersion, $File, $FileId) {
	$info = Get-CurseForgeModInfo $Ctx $ModId
	if ($info.Slug) {
		$project = Find-ModrinthProjectBySlug $info.Slug $info.Author
		if ($null -ne $project) {
			$release = Find-ModrinthRelease $Ctx $Kind $project.project_id $MatchVersion
			if ($null -ne $release.File) {
				$release.File.Note = "from Modrinth ($($project.title)), CurseForge blocks downloads"
				return $release.File
			}
		}
	}
	$File.Page = "$($info.Page)/files/$FileId"
	return $File
}
