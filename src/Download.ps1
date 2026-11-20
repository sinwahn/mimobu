# Putting the selected files into the output folder.
#
# The output folder keeps a list of the files this script placed there
# (.mimobu-files.json). A listed file the build no longer takes, such as the old
# jar of an updated mod, is moved to .old/ so Minecraft never sees two versions.
# Files the script did not place, like hand-downloaded jars, are never touched.

$script:ManifestName = '.mimobu-files.json'
$script:OldFilesDir = '.old'

function Read-FileManifest([string]$Path) {
	$manifest = @{}
	if (-not (Test-Path -LiteralPath $Path)) { return $manifest }
	$json = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
	foreach ($property in $json.PSObject.Properties) {
		$manifest[$property.Name] = @{ Kind = $property.Value.Kind; Key = $property.Value.Key }
	}
	return $manifest
}

function Save-FileManifest([string]$Path, [hashtable]$Manifest) {
	$sorted = [ordered]@{}
	foreach ($name in @($Manifest.Keys | Sort-Object)) {
		$sorted[$name] = [ordered]@{ Kind = $Manifest[$name].Kind; Key = $Manifest[$name].Key }
	}
	Write-TextFile $Path (ConvertTo-Json $sorted)
}

function Test-FileCurrent([string]$Path, [string]$Sha1) {
	if (-not (Test-Path -LiteralPath $Path)) { return $false }
	if (-not $Sha1) { return $true }
	return (Get-Sha1 $Path) -eq $Sha1.ToLowerInvariant()
}

# Downloads next to the target and moves into place only after the hash checks out,
# so a broken download never leaves a half-written jar behind.
function Install-File($File, [string]$Destination) {
	$partial = "$Destination.part"
	try {
		Save-Url $File.Url $partial
		if ($File.Sha1 -and (Get-Sha1 $partial) -ne $File.Sha1.ToLowerInvariant()) {
			throw 'downloaded file does not match its published hash'
		}
		Move-Item -LiteralPath $partial $Destination -Force
	} finally {
		if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
	}
}

# Returns one result per selected asset and per moved-away file:
# @{ Kind; Key; FileName; Status; Detail }, Status being one of
# current, downloaded, new, replace (dry run), manual, failed, moved, move (dry run).
function Sync-Files($Ctx, [string]$OutputDir, [bool]$Overwrite, [bool]$DryRun) {
	$outputRoot = Get-FullPath $OutputDir
	$manifestPath = Join-Path $outputRoot $script:ManifestName
	$previous = Read-FileManifest $manifestPath
	$placed = @{}
	$keep = New-Object 'System.Collections.Generic.HashSet[string]'
	$results = New-Object 'System.Collections.Generic.List[object]'

	foreach ($skip in $Ctx.Skipped) {
		if ($skip.Failed) { [void]$keep.Add("$($skip.Kind)::$($skip.Key)") }
	}

	foreach ($kind in $script:AssetKinds) {
		$folder = Join-Path $outputRoot $kind
		foreach ($key in @($Ctx.Selection[$kind].Keys | Sort-Object)) {
			$file = $Ctx.Selection[$kind][$key].Release.File
			$destination = Join-Path $folder $file.FileName
			$result = @{ Kind = $kind; Key = $key; FileName = $file.FileName; Detail = $file.Note }

			$present = Test-FileCurrent $destination $file.Sha1
			if (-not $file.Url) {
				if ($present) {
					$result.Status = 'current'
				} else {
					$result.Status = 'manual'
					$result.Detail = $file.Page
					[void]$keep.Add("${kind}::$key")  # the old file serves until the new one is fetched by hand
				}
			} elseif ($present -and -not $Overwrite) {
				$result.Status = 'current'
			} elseif ($DryRun) {
				$result.Status = if (Test-Path -LiteralPath $destination) { 'replace' } else { 'new' }
			} else {
				try {
					if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
					Install-File $file $destination
					$result.Status = 'downloaded'
					Write-Info "+ $kind/$($file.FileName)" Green
				} catch {
					$result.Status = 'failed'
					$result.Detail = $_.Exception.Message
					[void]$keep.Add("${kind}::$key")
					Write-Info "x $kind/$($file.FileName): $($result.Detail)" Red
				}
			}
			if ($result.Status -in 'current', 'downloaded', 'new', 'replace') {
				$placed["$kind/$($file.FileName)"] = @{ Kind = $kind; Key = $key }
			}
			$results.Add($result)
		}
	}

	foreach ($name in @($previous.Keys)) {
		if ($placed.ContainsKey($name)) { continue }
		$entry = $previous[$name]
		$path = Join-Path $outputRoot $name
		if ($keep.Contains("$($entry.Kind)::$($entry.Key)")) {
			# its lookup or download broke this time; the old file is still the best one
			if (Test-Path -LiteralPath $path) { $placed[$name] = $entry }
			continue
		}
		if (-not (Test-Path -LiteralPath $path)) { continue }
		$result = @{ Kind = $entry.Kind; Key = $entry.Key; FileName = (Split-Path -Leaf $name) }
		if ($DryRun) {
			$result.Status = 'move'
		} else {
			$target = Join-Path (Join-Path $outputRoot $script:OldFilesDir) $name
			$targetFolder = Split-Path -Parent $target
			if (-not (Test-Path -LiteralPath $targetFolder)) { New-Item -ItemType Directory -Path $targetFolder | Out-Null }
			Move-Item -LiteralPath $path $target -Force
			$result.Status = 'moved'
			Write-Info "> $name moved to $script:OldFilesDir (no longer in the build)" DarkYellow
		}
		$results.Add($result)
	}

	if (-not $DryRun -and ($placed.Count -gt 0 -or $previous.Count -gt 0)) {
		if (-not (Test-Path -LiteralPath $outputRoot)) { New-Item -ItemType Directory -Path $outputRoot | Out-Null }
		Save-FileManifest $manifestPath $placed
	}
	return , $results.ToArray()
}
