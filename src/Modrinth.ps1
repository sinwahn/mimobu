# Modrinth API: file lookup, project info, search.

$script:ModrinthApi = 'https://api.modrinth.com/v2'

function ConvertTo-ModrinthList([string[]]$Values) {
	return [uri]::EscapeDataString('["' + ($Values -join '","') + '"]')
}

# The newest file of a project for the build's game version (and loader, for mods;
# resource packs carry no mod loader tag). Without $MatchVersion any game version counts.
function Find-ModrinthRelease($Ctx, [string]$Kind, [string]$ProjectId, [bool]$MatchVersion) {
	$query = @()
	if ($Kind -eq 'mods') { $query += 'loaders=' + (ConvertTo-ModrinthList @($Ctx.Loader)) }
	if ($MatchVersion) { $query += 'game_versions=' + (ConvertTo-ModrinthList @($Ctx.GameVersion)) }
	$uri = "$script:ModrinthApi/project/$ProjectId/version"
	if ($query.Count -gt 0) { $uri += '?' + ($query -join '&') }

	$versions = @(Invoke-Api $uri)
	if ($versions.Count -eq 0) { return New-Release -Reason (Get-NoMatchReason $Ctx $Kind $MatchVersion) }

	$version = $versions[0]
	$file = @($version.files | Where-Object { $_.primary })[0]
	if ($null -eq $file) { $file = @($version.files)[0] }

	$dependencies = foreach ($dep in @($version.dependencies)) {
		if ($dep.dependency_type -notin 'required', 'optional') { continue }
		@{
			Source    = 'modrinth'
			Id        = $dep.project_id
			VersionId = $dep.version_id
			Required  = ($dep.dependency_type -eq 'required')
		}
	}
	return New-Release -Exact $MatchVersion -Dependencies @($dependencies) -File @{
		Url      = $file.url
		FileName = $file.filename
		Sha1     = $file.hashes.sha1
	}
}

function Get-ModrinthProjectInfo([string]$ProjectId) {
	$project = Invoke-Api "$script:ModrinthApi/project/$ProjectId"
	return @{ Name = $project.title; Slug = $project.slug; Id = $project.id }
}

# Some dependencies name only a version; this finds the project it belongs to.
function Get-ModrinthProjectOfVersion([string]$VersionId) {
	return (Invoke-Api "$script:ModrinthApi/version/$VersionId").project_id
}

# The Modrinth project with exactly this slug, or else one by the hinted author.
function Find-ModrinthProjectBySlug([string]$Slug, [string]$AuthorHint) {
	$hits = @((Invoke-Api "$script:ModrinthApi/search?query=$([uri]::EscapeDataString($Slug))&limit=5").hits)
	$exact = @($hits | Where-Object { $_.slug -eq $Slug })[0]
	if ($null -ne $exact) { return $exact }
	if ($AuthorHint) { return @($hits | Where-Object { $_.author -like "*$AuthorHint*" })[0] }
	return $null
}
