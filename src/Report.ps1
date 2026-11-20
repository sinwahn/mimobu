# The end-of-run summary.

function Get-ViaGroup([string]$Via) {
	switch -Wildcard ($Via) {
		'module *' { return 'modules' }
		'integration*' { return 'integrations' }
		'dependency*' { return 'dependencies' }
		default { return 'additions' }
	}
}

function Write-Group([string]$Title, $Lines, [string]$Color = 'Gray') {
	$items = @($Lines)
	if ($items.Count -eq 0) { return }
	Write-Host ''
	Write-Host "   $Title ($($items.Count)):" -ForegroundColor $Color
	foreach ($line in $items) { Write-Host "     $line" -ForegroundColor $Color }
}

function Write-Summary($Ctx, $Files, [string]$OutputDir, [bool]$DryRun) {
	$loaderNote = if ($Ctx.Loader -ne $Ctx.RequestedLoader) { " ($($Ctx.Loader) files)" } else { '' }
	Write-Step "Summary for $($Ctx.GameVersion) $($Ctx.RequestedLoader)$loaderNote$(if ($DryRun) { ', dry run: nothing written' })"

	$byGroup = @{}
	foreach ($entry in $Ctx.Selection.mods.Values) {
		$group = Get-ViaGroup $entry.Via
		$byGroup[$group] = 1 + [int]$byGroup[$group]
	}
	$parts = foreach ($group in 'modules', 'integrations', 'dependencies', 'additions') {
		if ($byGroup[$group]) { "$($byGroup[$group]) from $group" }
	}
	Write-Info "Mods: $($Ctx.Selection.mods.Count)$(if ($parts) { " ($($parts -join ', '))" })" White
	Write-Info "Resource packs: $($Ctx.Selection.resourcepacks.Count)" White

	$counts = @{}
	foreach ($file in $Files) { $counts[$file.Status] = 1 + [int]$counts[$file.Status] }
	$labels = [ordered]@{
		downloaded = 'downloaded'; new = 'to download'; replace = 'to download again'
		current = 'up to date'; moved = "moved to $(Join-Path $OutputDir $script:OldFilesDir)"; move = 'to move to .old'
	}
	$fileParts = foreach ($status in $labels.Keys) {
		if ($counts[$status]) { "$($counts[$status]) $($labels[$status])" }
	}
	if ($fileParts) { Write-Info "Files: $($fileParts -join ', ')" White }

	# "not in assets.yaml" is listed under the problems, with where the name came from
	$skipped = @($Ctx.Skipped | Where-Object {
			-not $Ctx.Selection[$_.Kind].Contains($_.Key) -and -not (Test-Active $Ctx $_.Key) -and
			$_.Reason -ne 'not in assets.yaml'
		})
	foreach ($failed in $false, $true) {
		$group = @($skipped | Where-Object { $_.Failed -eq $failed })
		foreach ($reason in @($group | ForEach-Object { $_.Reason } | Sort-Object -Unique)) {
			$keys = @($group | Where-Object { $_.Reason -eq $reason } | ForEach-Object { $_.Key } | Sort-Object -Unique)
			$title = if ($failed) { "Could not check, $reason" } else { "Left out, $reason" }
			$color = if ($failed) { 'Red' } else { 'DarkGray' }
			Write-Host ''
			Write-Host "   $title ($($keys.Count)):" -ForegroundColor $color
			Write-Host "     $($keys -join ', ')" -ForegroundColor $color
		}
	}

	Write-Group 'Downloads that failed' @($Files | Where-Object { $_.Status -eq 'failed' } |
			ForEach-Object { "$($_.Key): $($_.Detail)" }) Red
	Write-Group "Download by hand (CurseForge blocks these), then put them in $OutputDir" @($Files |
			Where-Object { $_.Status -eq 'manual' } |
			ForEach-Object { "$($_.Kind)/$($_.FileName)  from  $($_.Detail)" }) Yellow
	Write-Group 'Needs your attention' @($Ctx.Problems) Yellow

	Write-Host ''
	Write-Info 'Run with -Verbose to see every decision.' DarkGray
}
