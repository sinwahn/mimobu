# assets.yaml: finding entries by site id, adding discovered ones, saving.

function Find-AssetKey($Ctx, [string]$Source, [string]$Id) {
	if ($null -eq $Ctx.AssetIndex) {
		$Ctx.AssetIndex = @{}
		foreach ($key in $Ctx.Assets.mods.Keys) {
			$entry = $Ctx.Assets.mods[$key]
			$Ctx.AssetIndex["$($entry.source)::$($entry.mod_id)"] = $key
		}
	}
	return $Ctx.AssetIndex["${Source}::$Id"]
}

# Adds a mod found as a dependency to the catalog and returns its key. A mod whose
# name matches an existing entry is that entry, listed under its other site.
function Register-DiscoveredAsset($Ctx, [string]$Source, [string]$Id) {
	try {
		$info = Get-ProjectInfo $Ctx $Source $Id
	} catch {
		Write-Verbose "cannot fetch $Source project ${Id}: $($_.Exception.Message)"
		return $null
	}
	if ($null -eq $info -or -not $info.Name) { return $null }

	$key = ConvertTo-AssetKey $info.Name
	if (-not (Test-MapKey $Ctx.Assets.mods $key)) {
		$entry = [ordered]@{ name = $info.Name; source = $Source; mod_id = $Id }
		$Ctx.Assets.mods[$key] = $entry
		$Ctx.Discovered[$key] = $entry
		Write-Verbose "discovered $key ($Source $Id)"
	}
	if ($null -ne $Ctx.AssetIndex) { $Ctx.AssetIndex["${Source}::$Id"] = $key }
	return $key
}

function ConvertTo-SortedCatalogSection($Section) {
	$sorted = [ordered]@{}
	foreach ($key in @($Section.Keys | Sort-Object)) {
		$entry = $Section[$key]
		$ordered = [ordered]@{ name = $entry.name; source = $entry.source; mod_id = "$($entry.mod_id)" }
		foreach ($field in $entry.Keys) {
			if (-not $ordered.Contains($field)) { $ordered[$field] = $entry[$field] }
		}
		$sorted[$key] = $ordered
	}
	return $sorted
}

# Writes the catalog sorted by key, keeping the previous file as <file>.bak.
function Save-AssetCatalog($Assets, [string]$Path) {
	$full = Get-FullPath $Path
	if (Test-Path -LiteralPath $full) { Copy-Item -LiteralPath $full "$full.bak" -Force }
	$document = [ordered]@{
		resourcepacks = ConvertTo-SortedCatalogSection $Assets.resourcepacks
		mods          = ConvertTo-SortedCatalogSection $Assets.mods
	}
	Write-TextFile $full (ConvertTo-Yaml $document)
}
