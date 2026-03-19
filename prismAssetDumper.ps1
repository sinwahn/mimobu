Import-Module powershell-yaml

$root = "../instances"

$mods = @{}
$resourcepacks = @{}

$instances = Get-ChildItem $root -Directory

foreach ($inst in $instances) {

	foreach ($type in @("mods", "resourcepacks")) {
		$indexDir = Join-Path $inst.FullName "minecraft\$type\.index"

		if (Test-Path $indexDir) {
			$files = Get-ChildItem $indexDir -Filter *.pw.toml

			foreach ($file in $files) {
				$text = Get-Content $file.FullName -Raw

				$nameMatch = [regex]::Match($text, "\nname\s*=\s*[""'](.*)[""']")
				if (-not $nameMatch.Success) { continue }

				$name = $nameMatch.Groups[1].Value
				$id = ($name.ToLower() -replace '[^a-z0-9]+', '_').Trim('_')

				$cfProject = [regex]::Match($text, "project-id\s*=\s*(\d+)")
				$cfFile    = [regex]::Match($text, "file-id\s*=\s*(\d+)")
				$mrMod     = [regex]::Match($text, "mod-id\s*=\s*'([^']+)'")
				$mrVersion = [regex]::Match($text, "version\s*=\s*'([^']+)'")

				if ($cfProject.Success -and $cfFile.Success) {
					$mod_id = $cfProject.Groups[1].Value
					$source = "curseforge"
				} elseif ($mrMod.Success -and $mrVersion.Success) {
					$mod_id = $mrMod.Groups[1].Value
					$source = "modrinth"
				} else {
					continue
				}

				$entry = @{
					name   = $name
					source = $source
					mod_id = $mod_id
				}

				if ($type -eq "mods") {
					if (-not $mods.ContainsKey($id)) { $mods[$id] = $entry }
				} else {
					if (-not $resourcepacks.ContainsKey($id)) { $resourcepacks[$id] = $entry }
				}
			}
		}
	}
}

$modsSorted = [ordered]@{}
foreach ($k in ($mods.Keys | Sort-Object)) { $modsSorted[$k] = $mods[$k] }

$rpSorted = [ordered]@{}
foreach ($k in ($resourcepacks.Keys | Sort-Object)) { $rpSorted[$k] = $resourcepacks[$k] }

@{ mods = $modsSorted; resourcepacks = $rpSorted } | ConvertTo-Yaml | Set-Content assets.yaml
