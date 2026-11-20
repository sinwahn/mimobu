# Required dependencies of every selected mod, followed until nothing new arrives.

function Add-Dependencies($Ctx) {
	$done = New-Object 'System.Collections.Generic.HashSet[string]'
	do {
		$pending = @($Ctx.Selection.mods.Keys | Where-Object { -not $done.Contains($_) })
		foreach ($key in $pending) {
			[void]$done.Add($key)
			foreach ($dependency in $Ctx.Selection.mods[$key].Release.Dependencies) {
				if ($dependency.Required) {
					Add-Dependency $Ctx $dependency $key
				} else {
					Write-Verbose "$key has optional dependency $($dependency.Source) $($dependency.Id)"
				}
			}
		}
	} while ($pending.Count -gt 0)
}

function Add-Dependency($Ctx, $Dependency, [string]$Parent) {
	$source = $Dependency.Source
	$id = $Dependency.Id
	if (-not $id -and $Dependency.VersionId) {
		try {
			$id = Get-ModrinthProjectOfVersion $Dependency.VersionId
		} catch {
			Add-Problem $Ctx "$Parent needs Modrinth version $($Dependency.VersionId), which cannot be looked up: $($_.Exception.Message)"
			return
		}
	}

	$key = Find-AssetKey $Ctx $source $id
	if (-not $key) { $key = Register-DiscoveredAsset $Ctx $source $id }
	if (-not $key) {
		Add-Problem $Ctx "$Parent needs $source project $id, which cannot be found; add it to assets.yaml by hand"
		return
	}
	if (-not (Add-Asset $Ctx 'mods' $key "dependency of $Parent")) {
		$skip = $Ctx.Skipped[$Ctx.Skipped.Count - 1]
		# a failed lookup is already reported with the other failures
		if (-not $skip.Failed) { Add-Problem $Ctx "$Parent needs $key, which is left out: $($skip.Reason)" }
	}
}
