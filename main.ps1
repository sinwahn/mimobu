param(
	[string]$ModulesFile = "modules.yaml",
	[string]$AssetsFile = "assets.yaml",
	[string]$BuildFile = "build.yaml",
	[string]$OutputDir = "output",
	[bool]$OverwriteExisting = $false
)

Write-Host "`n=== BUILD AUTOMATION START ===" -ForegroundColor Green
Write-Host "Config files: modules -> $ModulesFile | assets -> $AssetsFile | build -> $BuildFile" -ForegroundColor Cyan

# ====================== YAML DEPENDENCY ======================
if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
	Write-Host "[INSTALL] powershell-yaml not found - installing..." -ForegroundColor Yellow
	Install-Module -Name powershell-yaml -Force -Scope CurrentUser
	Import-Module powershell-yaml
	Write-Host "[INSTALL] powershell-yaml successfully installed" -ForegroundColor Green
} else {
	Write-Host "[INSTALL] powershell-yaml already available" -ForegroundColor DarkGray
}

function Read-YamlConfig($path) {
	try {
		return ConvertFrom-Yaml (Get-Content $path -Raw)
	} catch {
		Write-Host "[CONFIG] ERROR reading $path : $($_.Exception.Message)" -ForegroundColor Red
		exit 1
	}
}

$modulesData = Read-YamlConfig $ModulesFile
$assetRegistry = Read-YamlConfig $AssetsFile
$buildData = Read-YamlConfig $BuildFile

$mcVersion = $buildData.version
$modloader = $buildData.modloader.ToLower()

if ($modloader -eq "neoforge" -and $mcVersion -match '^1\.(\d+)') {
	$minor = [int]$Matches[1]
	if ($minor -le 19) {
		$modloader = "forge"
	} elseif ($minor -eq 20 -and $mcVersion -notmatch '^1\.20\.1$') {
		# 1.20.2+ neoforge is incompatible with forge, keep neoforge
	} elseif ($minor -eq 20) {
		# 1.20.1 only: neoforge didn't have wide adoption, forge tags are authoritative
		$modloader = "forge"
	}
}

Write-Host "[CONFIG] MC Version: $mcVersion | Modloader: $modloader" -ForegroundColor Cyan

$cfApiKey = $buildData.cf_api_key

# compat cache: modKey -> $true/$false
$compatCache = @{}

$modLoaderTypeMap = @{
	"forge" = 1
	"fabric" = 4
	"quilt" = 5
	"neoforge" = 6
}

function Resolve-ModEntry($entry) {
	if ($entry -is [string]) {
		return @{ key = $entry; pinned = $false }
	}
	if ($entry -is [hashtable]) {
		$key = @($entry.Keys)[0]
		$flags = $entry[$key]
		return @{ key = $key; pinned = ($flags -is [hashtable] -and $flags.pinned -eq $true) }
	}
	return $null
}

function Test-ModCompat-Generic($key, $namespace = "mods") {
	$cacheKey = "${namespace}::${key}"
	if ($compatCache.ContainsKey($cacheKey)) {
		Write-Host "    [COMPAT-CACHE] $cacheKey returned from cache" -ForegroundColor DarkGray
		return $compatCache[$cacheKey]
	}

	if (-not $assetRegistry.$namespace.Contains($key)) {
		Write-Host "    [COMPAT] $key NOT FOUND in $namespace registry" -ForegroundColor Yellow
		$compatCache[$cacheKey] = $false
		return $false
	}

	$mod = $assetRegistry.$namespace[$key]
	$source = $mod.source
	$id = $mod.mod_id
	$ok = $false

	try {
		if ($source -eq "modrinth") {
			$loaderJson  = '["' + $modloader + '"]'
			$versionJson = '["' + $mcVersion + '"]'
			$uri = "https://api.modrinth.com/v2/project/$id/version?loaders=$([uri]::EscapeDataString($loaderJson))&game_versions=$([uri]::EscapeDataString($versionJson))"
			$r  = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
			$ok = $r.Count -gt 0
			if ($ok) {
				Write-Host "    [COMPAT] $key with $modloader $mcVersion (Modrinth)" -ForegroundColor Green
			} else {
				Write-Host "    [COMPAT] $key - no versions match" -ForegroundColor Yellow
			}

		} elseif ($source -eq "curseforge") {
			$loaderInt = $modLoaderTypeMap[$modloader.ToLower()]
			if ($null -eq $loaderInt) {
				Write-Host "    [COMPAT] $key unknown modloader '$modloader'" -ForegroundColor Red
				$compatCache[$cacheKey] = $false
				return $false
			}
			$uri    = "https://api.curseforge.com/v1/mods/$id/files?gameVersion=$mcVersion&modLoaderType=$loaderInt&pageSize=1"
			$output = curl.exe -s $uri -H "Accept: application/json" -H "x-api-key: $cfApiKey"
			$data   = ($output | ConvertFrom-Json).data
			$ok     = $data.Count -gt 0
			if ($ok) {
				Write-Host "    [COMPAT] $key with $modloader $mcVersion (CurseForge)" -ForegroundColor Green
			} else {
				Write-Host "    [COMPAT] $key - no versions match" -ForegroundColor Yellow
			}

		} else {
			Write-Host "    [COMPAT] $key unknown source '$source'" -ForegroundColor Red
		}
	} catch {
		Write-Host "    [COMPAT-ERROR] $key API error: $($_.Exception.Message)" -ForegroundColor Red
	}

	$compatCache[$cacheKey] = $ok
	return $ok
}

# keep old name as a wrapper so nothing else breaks
function Test-ModCompat($key) { return Test-ModCompat-Generic $key "mods" }

# ====================== MODULE RESOLUTION ======================
$selectedMods = [System.Collections.Generic.HashSet[string]]::new()
$pinnedMods = [System.Collections.Generic.HashSet[string]]::new()
$selectedResourcepacks = [System.Collections.Generic.HashSet[string]]::new()
$pinnedResourcepacks  = [System.Collections.Generic.HashSet[string]]::new()
$activeModules = [System.Collections.Generic.HashSet[string]]::new()

function Test-Active($key) {
	if ($selectedMods.Contains($key)) { return $true }
	if ($modulesData.platform_mods.ContainsKey($key)) {
		return [bool]($modulesData.platform_mods[$key] | Where-Object { $selectedMods.Contains($_) })
	}
	return $false
}

function Resolve-PlatformMod($virtualKey) {
	Write-Host "    [PLATFORM] Resolving virtual mod '$virtualKey'..." -ForegroundColor DarkGray
	$candidates = $modulesData.platform_mods[$virtualKey]
	Write-Host "        Candidates: $($candidates -join ', ')" -ForegroundColor DarkGray
	
	foreach ($candidate in $candidates) {
		if (Test-ModCompat $candidate) {
			Write-Host "        Selected: $candidate" -ForegroundColor Green
			return $candidate
		}
	}
	Write-Host "        No compatible variant found" -ForegroundColor Yellow
	return $null
}

function Try-Add-Mod($key, $pinned = $false) {
	if ($modulesData.platform_mods.ContainsKey($key)) {
		$real = Resolve-PlatformMod $key
		if ($null -eq $real) { return $null }
		if ($selectedMods.Add($real)) { }
		return $null
	}

	if (-not $assetRegistry.mods.Contains($key)) { return $null }

	if ($pinned) {
		Write-Host "    [PINNED] $key forced into selection regardless of compat" -ForegroundColor Magenta
		[void]$pinnedMods.Add($key)
	} elseif (-not (Test-ModCompat $key)) {
		return $null
	}

	if ($selectedMods.Add($key)) { }
	return $null
}

function Try-Add-Resourcepack($key, $pinned = $false) {
	if (-not $assetRegistry.resourcepacks.Contains($key)) { return $null }

	if ($pinned) {
		Write-Host "    [PINNED] $key forced into selection regardless of compat" -ForegroundColor Magenta
		[void]$pinnedResourcepacks.Add($key)
	} elseif (-not (Test-ModCompat-Generic $key "resourcepacks")) {
		return $null
	}

	if ($selectedResourcepacks.Add($key)) { }
	return $null
}

function Resolve-Module($name) {
	if ($activeModules.Contains($name)) {
		Write-Host "[RESOLVE] $name already resolved, skipping" -ForegroundColor Gray
		return
	}

	if ($modulesData.main_modules.ContainsKey($name)) {
		[void]$activeModules.Add($name)
		Write-Host "Module $name" -ForegroundColor DarkGray
		foreach ($entry in $modulesData.main_modules[$name].mods) {
			$parsed = Resolve-ModEntry $entry
			if ($null -ne $parsed) { Try-Add-Mod $parsed.key $parsed.pinned }
		}
		foreach ($entry in $modulesData.main_modules[$name].resourcepacks) {
			$parsed = Resolve-ModEntry $entry
			if ($null -ne $parsed) { Try-Add-Resourcepack $parsed.key $parsed.pinned }
		}
		return
	}

	if ($modulesData.sub_modules.ContainsKey($name)) {
		$sm = $modulesData.sub_modules[$name]
		
		# Check dependencies
		if ($sm.depends_module -and $sm.depends_module.Count -gt 0) {
			Write-Host "Sub module $name $($sm.depends_module -join ', ')" -ForegroundColor Yellow
			$depsMissing = @()
			foreach ($dep in $sm.depends_module) {
				if (-not $activeModules.Contains($dep)) {
					$depsMissing += $dep
				}
			}
			
			if ($depsMissing.Count -gt 0) {
				Write-Host "    Missing dependencies: $($depsMissing -join ', ')" -ForegroundColor Red
				return
			}
		}
		
		[void]$activeModules.Add($name)
		Write-Host "Sub module $name" -ForegroundColor Green
		Write-Host "    Mods: $($sm.mods -join ', ')" -ForegroundColor DarkGray
		foreach ($mod in $sm.mods) {
			Try-Add-Mod $mod
		}
		foreach ($rp in $sm.resourcepacks) {
			Try-Add-Resourcepack $rp
		}
		return
	}

	Write-Host "SKIP $name - unknown module (not in main_modules or sub_modules)" -ForegroundColor Red
}

# ====================== COLLECTING MODULES ======================
Write-Host "`n=== COLLECTING CONTENT FROM REQUESTED MODULES ===" -ForegroundColor Green
Write-Host "Requested modules: $($buildData.modules -join ', ')" -ForegroundColor Cyan

foreach ($req in $buildData.modules) {
	Resolve-Module $req
}

Write-Host "`n[MODULES] Resolved count: $($activeModules.Count)" -ForegroundColor Green
Write-Host "[MODULES] Active: $(($activeModules | Sort-Object) -join ', ')" -ForegroundColor Cyan

# ====================== INTEGRATION PROCESSING ======================
if ($buildData.allow_integrations) {
	Write-Host "`n=== PROCESSING INTEGRATIONS ===" -ForegroundColor Green

	# --- one2other ---
	$integrationsAdded = 0
	
	if ($modulesData.integrations.one2other) {
		Write-Host "[ONE2OTHER] Processing mappings..." -ForegroundColor Cyan
		foreach ($coreMod in $modulesData.integrations.one2other.Keys) {
			$hostActive = Test-Active $coreMod

			if (-not $hostActive) {
				Write-Host "[ONE2OTHER] Core mod '$coreMod' not active - skipping" -ForegroundColor DarkGray
			} else {
				Write-Host "[ONE2OTHER] Core mod '$coreMod' is active, checking integrations..." -ForegroundColor Gray
				$entries = $modulesData.integrations.one2other[$coreMod]
				foreach ($integrationMod in $entries.Keys) {
					$dependencyMod = $entries[$integrationMod]
					$depActive = Test-Active $dependencyMod
					if ($depActive) {
						Write-Host "    [ONE2OTHER] Adding $integrationMod (requires $dependencyMod)" -ForegroundColor Green
						Try-Add-Mod $integrationMod
						$integrationsAdded++
					} else {
						Write-Host "    [ONE2OTHER] SKIP $integrationMod - dependency '$dependencyMod' not present" -ForegroundColor DarkGray
					}
				}
			}
		}
	} else {
		Write-Host "[ONE2OTHER] No one2other section in modules" -ForegroundColor DarkGray
	}

	# --- manual ---
	if ($modulesData.integrations.manual) {
		Write-Host "[MANUAL] Evaluating manual integrations..." -ForegroundColor Cyan
		foreach ($intMod in $modulesData.integrations.manual.Keys) {
			$rule = $modulesData.integrations.manual[$intMod]

			if ($rule.ContainsKey("depends_mods")) {
				$ok = $true
				$missing = @()
				foreach ($dep in $rule.depends_mods) {
					if (-not (Test-Active $dep)) {
						$ok = $false
						$missing += $dep
					}
				}
				if (-not $ok) {
					Write-Host "[MANUAL] SKIP $intMod - missing: $($missing -join ', ')" -ForegroundColor DarkGray
					continue
				}
				Write-Host "[MANUAL] Trying to add $intMod" -ForegroundColor White
				Try-Add-Mod $intMod
				$integrationsAdded++
				if ($rule.ContainsKey("or_samecondition")) {
					Write-Host "    [MANUAL] Also trying aliases: $($rule.or_samecondition -join ', ')" -ForegroundColor DarkGray
					foreach ($alias in $rule.or_samecondition) {
						Try-Add-Mod $alias
					}
				}
				continue
			}

			if ($rule.ContainsKey("depends_mods_compound")) {
				function Test-Compound($node, [string]$ctx = "ROOT") {
					if ($node.ContainsKey("and")) {
						Write-Host "      [$ctx] AND block:" -ForegroundColor DarkGray
						foreach ($k in $node.and.Keys) {
							if (-not (Test-Active $k)) {
								Write-Host "        [$ctx.and] Missing '$k' -> AND FAIL" -ForegroundColor DarkGray
								return $false
							}
							Write-Host "        [$ctx.and] Found '$k'" -ForegroundColor DarkGray
							$v = $node.and[$k]
							if ($v -is [hashtable] -and $v.Count -gt 0) {
								if (-not (Test-Compound $v "$ctx.and.$k")) {
									Write-Host "        [$ctx.and] Sub-condition for '$k' failed -> AND FAIL" -ForegroundColor DarkGray
									return $false
								}
							}
						}
						Write-Host "      [$ctx] AND PASSED" -ForegroundColor DarkGray
						return $true
					}
					if ($node.ContainsKey("or")) {
						Write-Host "      [$ctx] OR block:" -ForegroundColor DarkGray
						foreach ($item in $node.or) {
							if (Test-Active $item) {
								Write-Host "        [$ctx.or] Found '$item' -> OR PASS" -ForegroundColor DarkGray
								return $true
							}
							Write-Host "        [$ctx.or] Missing '$item'" -ForegroundColor DarkGray
						}
						Write-Host "      [$ctx] OR FAIL - none matched" -ForegroundColor DarkGray
						return $false
					}
					Write-Host "      [$ctx] Unknown node structure -> FAIL" -ForegroundColor DarkGray
					return $false
				}
				Write-Host "    [MANUAL] Evaluating compound condition for $intMod" -ForegroundColor DarkGray
				if (Test-Compound $rule.depends_mods_compound "ROOT") {
					Write-Host "[MANUAL] Adding $intMod (compound condition met)" -ForegroundColor Green
					Try-Add-Mod $intMod
					$integrationsAdded++
				}
				else {
					Write-Host "[MANUAL] $intMod - compound condition not met" -ForegroundColor Gray
				}
				continue
			}
		}
	} else {
		Write-Host "[MANUAL] No manual section in modules" -ForegroundColor Gray
	}
	
	Write-Host "[INTEGRATIONS] Total added: $integrationsAdded" -ForegroundColor Green
} else {
	Write-Host "`n=== INTEGRATIONS DISABLED ===" -ForegroundColor Yellow
}

# ====================== ADDITIONAL CONTENT ======================
Write-Host "`n=== PROCESSING ADDITIONS ===" -ForegroundColor Green

if ($buildData.addition.mods) {
	Write-Host "[ADDITION] Adding $($buildData.addition.mods.Count) mods from build.yaml..." -ForegroundColor Cyan
	foreach ($mod in $buildData.addition.mods) {
		Try-Add-Mod $mod
	}
} else {
	Write-Host "[ADDITION] No additional mods specified" -ForegroundColor Gray
}

if ($buildData.addition.packages) {
	Write-Host "[ADDITION] Adding $($buildData.addition.packages.Count) packages..." -ForegroundColor Cyan
	foreach ($pkg in $buildData.addition.packages) {
		Write-Host "    PKG $pkg" -ForegroundColor White
	}
} else {
	Write-Host "[ADDITION] No additional packages specified" -ForegroundColor Gray
}

function Get-ModFile($key, $outputDir, $namespace = "mods", $pinned = $false) {
	if (-not $assetRegistry.$namespace.Contains($key)) {
		Write-Host "    [DOWNLOAD] $key NOT FOUND in $namespace registry" -ForegroundColor Yellow
		return $false
	}

	$mod    = $assetRegistry.$namespace[$key]
	$source = $mod.source
	$id     = $mod.mod_id

	try {
		if ($source -eq "modrinth") {
			$loaderJson  = '["' + $modloader + '"]'
			$versionJson = '["' + $mcVersion + '"]'
			$uri = "https://api.modrinth.com/v2/project/$id/version?loaders=$([uri]::EscapeDataString($loaderJson))&game_versions=$([uri]::EscapeDataString($versionJson))"
			$r = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
			if ($r.Count -eq 0) {
				if ($pinned) {
					Write-Host "    [DOWNLOAD] $key - pinned, no exact version match, attempting latest anyway" -ForegroundColor Yellow
					$loaderJson2 = '["' + $modloader + '"]'
					$uri2 = "https://api.modrinth.com/v2/project/$id/version?loaders=$([uri]::EscapeDataString($loaderJson2))&limit=1"
					$r = Invoke-RestMethod -Uri $uri2 -Method Get -ErrorAction Stop
					if ($r.Count -eq 0) {
						Write-Host "    [DOWNLOAD] $key - pinned but no files found at all" -ForegroundColor Red
						return $false
					}
				} else {
					Write-Host "    [DOWNLOAD] $key - no versions match" -ForegroundColor Yellow
					return $false
				}
			}
			$file = $r[0].files | Where-Object { $_.primary } | Select-Object -First 1
			if ($null -eq $file) { $file = $r[0].files[0] }
			$url      = $file.url
			$fileName = $file.filename

		} elseif ($source -eq "curseforge") {
			$loaderInt = $modLoaderTypeMap[$modloader.ToLower()]
			if ($null -eq $loaderInt) {
				Write-Host "    [DOWNLOAD] $key unknown modloader '$modloader'" -ForegroundColor Red
				return $false
			}
			$uri    = "https://api.curseforge.com/v1/mods/$id/files?gameVersion=$mcVersion&modLoaderType=$loaderInt&pageSize=1"
			$output = curl.exe -s $uri -H "Accept: application/json" -H "x-api-key: $cfApiKey"
			$data   = ($output | ConvertFrom-Json).data
			if ($data.Count -eq 0) {
				if ($pinned) {
					Write-Host "    [DOWNLOAD] $key - pinned, no exact version match, attempting latest anyway" -ForegroundColor Yellow
					$uri2 = "https://api.curseforge.com/v1/mods/$id/files?pageSize=1"
					$output2 = curl.exe -s $uri2 -H "Accept: application/json" -H "x-api-key: $cfApiKey"
					$data = ($output2 | ConvertFrom-Json).data
					if ($data.Count -eq 0) {
						Write-Host "    [DOWNLOAD] $key - pinned but no files found at all" -ForegroundColor Red
						return $false
					}
				} else {
					Write-Host "    [DOWNLOAD] $key - no versions match" -ForegroundColor Yellow
					return $false
				}
			}
			$url      = $data[0].downloadUrl
			$fileName = $data[0].fileName

			# CurseForge blocks 3rd party downloads when downloadUrl is empty
			if ([string]::IsNullOrEmpty($url)) {
				Write-Host "    [DOWNLOAD] $key - CurseForge blocks 3rd party download, trying Modrinth fallback..." -ForegroundColor Yellow
				$cfInfo = Get-CurseForgeModInfo $id
				$slug   = if ($cfInfo) { $cfInfo.slug } else { $null }
				$author = if ($cfInfo) { $cfInfo.authors | Select-Object -First 1 -ExpandProperty name } else { $null }

				if ($slug) {
					$mrResult = Search-ModrinthBySlug $slug $author
					if ($null -ne $mrResult) {
						$mrLoaderJson  = '["' + $modloader + '"]'
						$mrVersionJson = '["' + $mcVersion + '"]'
						$mrUri = "https://api.modrinth.com/v2/project/$($mrResult.project_id)/version?loaders=$([uri]::EscapeDataString($mrLoaderJson))&game_versions=$([uri]::EscapeDataString($mrVersionJson))"
						$mrVersions = Invoke-RestMethod -Uri $mrUri -Method Get -ErrorAction Stop
						if ($mrVersions.Count -gt 0) {
							$mrFile = $mrVersions[0].files | Where-Object { $_.primary } | Select-Object -First 1
							if ($null -eq $mrFile) { $mrFile = $mrVersions[0].files[0] }
							$url      = $mrFile.url
							$fileName = $mrFile.filename
							Write-Host "    [DOWNLOAD] $key - using Modrinth fallback: $($mrResult.title)" -ForegroundColor Yellow
						}
					}
				}

				if ([string]::IsNullOrEmpty($url)) {
					Write-Host "    [DOWNLOAD-ERROR] $key - CurseForge blocked and no Modrinth fallback found" -ForegroundColor Red
					Write-Host "    [DOWNLOAD-ERROR] Manually download this mod and place it in $outputDir" -ForegroundColor Red
					return $false
				}
			}

		} else {
			Write-Host "    [DOWNLOAD] $key unknown source '$source'" -ForegroundColor Red
			return $false
		}

		$dest = Join-Path $outputDir $fileName
		if (-not $OverwriteExisting -and (Test-Path $dest)) {
			Write-Host "    [DOWNLOAD] $key - skipping, $fileName already exists" -ForegroundColor DarkGray
			return "skipped"
		}

		Write-Host "    [DOWNLOAD] $key -> $fileName" -ForegroundColor Cyan
		curl.exe -s -L -o $dest $url
		return $true

	} catch {
		Write-Host "    [DOWNLOAD-ERROR] $key API error: $($_.Exception.Message)" -ForegroundColor Red
		return $false
	}
}

# ====================== DEPENDENCY RESOLUTION ======================
Write-Host "`n=== RESOLVING DEPENDENCIES ===" -ForegroundColor Green

$newRegistryEntries = @{}
$depVisited = [System.Collections.Generic.HashSet[string]]::new()

function Find-RegistryKeyByModId($modId, $namespace = "mods") {
	foreach ($k in $assetRegistry.$namespace.Keys) {
		if ($assetRegistry.$namespace[$k].mod_id -eq "$modId") { return $k }
	}
	return $null
}

function Get-ModrinthProjectInfo($projectId) {
	try {
		$r = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$projectId" -Method Get -ErrorAction Stop
		return $r
	} catch { return $null }
}

function Get-CurseForgeModInfo($modId) {
	try {
		$output = curl.exe -s "https://api.curseforge.com/v1/mods/$modId" -H "Accept: application/json" -H "x-api-key: $cfApiKey"
		return ($output | ConvertFrom-Json).data
	} catch { return $null }
}

function Search-ModrinthBySlug($slug, $authorHint) {
	try {
		$uri = "https://api.modrinth.com/v2/search?query=$([uri]::EscapeDataString($slug))&limit=5"
		$results = (Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop).hits
		$exact = $results | Where-Object { $_.slug -eq $slug } | Select-Object -First 1
		if ($null -ne $exact) { return $exact }
		if ($authorHint) {
			$fuzzy = $results | Where-Object { $_.author -ilike "*$authorHint*" } | Select-Object -First 1
			if ($null -ne $fuzzy) { return $fuzzy }
		}
		return $null
	} catch { return $null }
}

function Resolve-Dependency($depModId, $depSource, $chain) {
	$chainStr = $chain -join " -> "

	# circular guard
	$visitKey = "${depSource}::${depModId}"
	if ($depVisited.Contains($visitKey)) { return }
	[void]$depVisited.Add($visitKey)

	# check registry by mod_id
	$regKey = Find-RegistryKeyByModId $depModId "mods"
	if ($null -ne $regKey) {
		Write-Host "    [DEP] $chainStr -> $regKey (registry match)" -ForegroundColor Cyan
		Try-Add-Mod $regKey $false
		return
	}

	# not in registry - auto-discover
	Write-Host "    [DEP] $chainStr -> mod_id=$depModId not in registry, auto-discovering..." -ForegroundColor Yellow
	$name = $null
	$resolvedSource = $depSource
	$resolvedId = $depModId

	if ($depSource -eq "modrinth") {
		$info = Get-ModrinthProjectInfo $depModId
		if ($null -ne $info) {
			$name = $info.title
			$slug = $info.slug
		}
	} elseif ($depSource -eq "curseforge") {
		$info = Get-CurseForgeModInfo $depModId
		if ($null -ne $info) {
			$name = $info.name
			$slug = $info.slug
		} else {
			Write-Host "    [DEP] CurseForge fetch failed for mod_id=$depModId, trying Modrinth fallback..." -ForegroundColor Yellow
		}

		# try modrinth fallback regardless if CF blocked download later - discover now
		if ($null -ne $slug) {
			$mrResult = Search-ModrinthBySlug $slug ($info.authors | Select-Object -First 1 -ExpandProperty name)
			if ($null -ne $mrResult) {
				Write-Host "    [DEP] Modrinth fallback match: $($mrResult.title) (slug: $($mrResult.slug))" -ForegroundColor Yellow
				# prefer modrinth if CF download will be blocked (downloadUrl empty is checked at download time)
				# for now register both but keep CF as primary, modrinth as fallback key
				$fallbackKey = ($mrResult.title.ToLower() -replace '[^a-z0-9]+', '_').Trim('_') + "_mr_fallback"
				if (-not $newRegistryEntries.ContainsKey($fallbackKey) -and -not (Find-RegistryKeyByModId $mrResult.project_id "mods")) {
					$newRegistryEntries[$fallbackKey] = @{
						name = $mrResult.title
						source = "modrinth"
						mod_id = $mrResult.project_id
					}
					Write-Host "    [DEP] Registered Modrinth fallback entry: $fallbackKey" -ForegroundColor DarkGray
				}
			}
		}
	}

	if ($null -eq $name) {
		Write-Host "    [DEP-ERROR] Cannot resolve dependency mod_id=$depModId (source: $depSource)" -ForegroundColor Red
		Write-Host "    [DEP-ERROR] Chain: $chainStr" -ForegroundColor Red
		Write-Host "    [DEP-ERROR] Manually add this mod to build.yaml additions or modules" -ForegroundColor Red
		return
	}

	$autoKey = ($name.ToLower() -replace '[^a-z0-9]+', '_').Trim('_')

	# avoid duplicate keys
	if ($assetRegistry.mods.Contains($autoKey) -or $newRegistryEntries.ContainsKey($autoKey)) {
		$autoKey = $autoKey + "_dep_$depModId"
	}

	$newRegistryEntries[$autoKey] = @{
		name   = $name
		source = $resolvedSource
		mod_id = "$resolvedId"
	}
	Write-Host "    [DEP] New registry entry: $autoKey (source: $resolvedSource, id: $resolvedId)" -ForegroundColor Magenta
	Write-Host "    [DEP] Added to registry and informing user: '$name' was auto-discovered" -ForegroundColor Magenta

	# temporarily inject into assetRegistry so Try-Add-Mod and compat work immediately
	$assetRegistry.mods[$autoKey] = $newRegistryEntries[$autoKey]
	Try-Add-Mod $autoKey $false
}

function Get-ModDependencies($key) {
	if (-not $assetRegistry.mods.Contains($key)) { return }

	$mod = $assetRegistry.mods[$key]
	$source = $mod.source
	$id = $mod.mod_id
	$chain = @($key)

	try {
		if ($source -eq "modrinth") {
			$loaderJson  = '["' + $modloader + '"]'
			$versionJson = '["' + $mcVersion + '"]'
			$uri = "https://api.modrinth.com/v2/project/$id/version?loaders=$([uri]::EscapeDataString($loaderJson))&game_versions=$([uri]::EscapeDataString($versionJson))"
			$versions = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
			if ($versions.Count -eq 0) { return }

			$deps = $versions[0].dependencies
			foreach ($dep in $deps) {
				if ($dep.dependency_type -eq "required") {
					$depId = if ($dep.project_id) { $dep.project_id } else { $dep.version_id }
					if ($depId) { Resolve-Dependency $depId "modrinth" ($chain + @($depId)) }
				} elseif ($dep.dependency_type -eq "optional") {
					Write-Host "    [DEP-OPT] $key has optional dependency: $($dep.project_id) - add manually to build.yaml if needed" -ForegroundColor Yellow
				}
			}

		} elseif ($source -eq "curseforge") {
			$loaderInt = $modLoaderTypeMap[$modloader.ToLower()]
			$uri    = "https://api.curseforge.com/v1/mods/$id/files?gameVersion=$mcVersion&modLoaderType=$loaderInt&pageSize=1"
			$output = curl.exe -s $uri -H "Accept: application/json" -H "x-api-key: $cfApiKey"
			$data   = ($output | ConvertFrom-Json).data
			if ($data.Count -eq 0) { return }

			$deps = $data[0].dependencies
			foreach ($dep in $deps) {
				if ($dep.relationType -eq 3) {
					Resolve-Dependency "$($dep.modId)" "curseforge" ($chain + @("$($dep.modId)"))
				} elseif ($dep.relationType -eq 2) {
					Write-Host "    [DEP-OPT] $key has optional dependency: CF mod_id=$($dep.modId) - add manually to build.yaml if needed" -ForegroundColor Yellow
				}
			}
		}
	} catch {
		Write-Host "    [DEP-ERROR] Failed fetching deps for $key : $($_.Exception.Message)" -ForegroundColor Red
	}
}

# Process all selected mods recursively until no new ones are added
$processedForDeps = [System.Collections.Generic.HashSet[string]]::new()
$iteration = 0
do {
	$iteration++
	$snapshot = @($selectedMods | Where-Object { -not $processedForDeps.Contains($_) })
	Write-Host "[DEP] Iteration $iteration - processing $($snapshot.Count) mods for dependencies" -ForegroundColor Cyan
	foreach ($key in $snapshot) {
		[void]$processedForDeps.Add($key)
		Get-ModDependencies $key
	}
} while (($selectedMods | Where-Object { -not $processedForDeps.Contains($_) }).Count -gt 0)

Write-Host "[DEP] Dependency resolution complete. Total mods: $($selectedMods.Count)" -ForegroundColor Green

# ====================== REGISTRY UPDATE ======================
if ($newRegistryEntries.Count -gt 0) {
	Write-Host "`n=== UPDATING ASSET REGISTRY ===" -ForegroundColor Green
	Write-Host "[REGISTRY] Adding $($newRegistryEntries.Count) auto-discovered entries to $AssetsFile" -ForegroundColor Magenta

	foreach ($k in $newRegistryEntries.Keys) {
		Write-Host "    [REGISTRY] + $k ($($newRegistryEntries[$k].source) / $($newRegistryEntries[$k].mod_id))" -ForegroundColor Magenta
		# already injected into $assetRegistry.mods above, just need to persist
	}

	# rebuild sorted mods section including new entries and write back
	$allMods = [ordered]@{}
	foreach ($k in (($assetRegistry.mods.Keys) | Sort-Object)) {
		$allMods[$k] = $assetRegistry.mods[$k]
	}
	$assetRegistry.mods = $allMods
	Copy-Item $AssetsFile "$AssetsFile.bak" -Force
	@{ mods = $assetRegistry.mods; resourcepacks = $assetRegistry.resourcepacks } | ConvertTo-Yaml | Set-Content $AssetsFile
	Write-Host "[REGISTRY] Saved updated $AssetsFile" -ForegroundColor Green
} else {
	Write-Host "[REGISTRY] No new entries to add" -ForegroundColor DarkGray
}

# ====================== DOWNLOAD PHASE ======================
Write-Host "`n=== DOWNLOADING FILES ===" -ForegroundColor Green

if (-not (Test-Path $outputDir)) {
	New-Item -ItemType Directory -Path $outputDir | Out-Null
	Write-Host "[DOWNLOAD] Created output directory: $outputDir" -ForegroundColor DarkGray
}

$downloadedCount = 0
$skippedCount = 0
$failedCount = 0

foreach ($key in ($selectedMods | Sort-Object)) {
    $isPinned = $pinnedMods.Contains($key)

	$modsFolder = "$outputDir/mods"
	if (-not (Test-Path $modsFolder)) {
		New-Item -ItemType Directory -Path $modsFolder | Out-Null
		Write-Host "[DOWNLOAD] Created mods directory: $modsFolder" -ForegroundColor DarkGray
	}

    $result = Get-ModFile $key $modsFolder "mods" $isPinned
	if ($result -eq "skipped") { $skippedCount++ }
	elseif ($result) { $downloadedCount++ }
	else { $failedCount++ }
}

foreach ($key in ($selectedResourcepacks | Sort-Object)) {
    $isPinned = $pinnedResourcepacks.Contains($key)
	
	$resourcepacksFolder = "$outputDir/resourcepacks"
	if (-not (Test-Path $resourcepacksFolder)) {
		New-Item -ItemType Directory -Path $resourcepacksFolder | Out-Null
		Write-Host "[DOWNLOAD] Created mods directory: $resourcepacksFolder" -ForegroundColor DarkGray
	}

	$result = Get-ModFile $key $resourcepacksFolder "resourcepacks" $isPinned
	if ($result -eq "skipped") { $skippedCount++ }
	elseif ($result) { $downloadedCount++ }
	else { $failedCount++ }
}

Write-Host "[DOWNLOAD] Done - downloaded: $downloadedCount, skipped: $skippedCount, failed: $failedCount" -ForegroundColor Green


# ====================== FINAL SUMMARY ======================
Write-Host "`n=== BUILD AUTOMATION COMPLETE ===" -ForegroundColor Green
Write-Host "Total mods selected: $($selectedMods.Count)" -ForegroundColor Green
Write-Host "Selected mods: $(($selectedMods | Sort-Object) -join ', ')" -ForegroundColor Cyan
Write-Host "Total resourcepacks selected: $($selectedResourcepacks.Count)" -ForegroundColor Green
Write-Host "Selected resourcepacks: $(($selectedResourcepacks | Sort-Object) -join ', ')" -ForegroundColor Cyan
Write-Host ""
