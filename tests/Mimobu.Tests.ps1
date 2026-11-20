# Run with: Invoke-Pester ./tests   (Pester 5)
# No test touches the network: Invoke-Api and Save-Url are replaced by fakes.
# fixtures/modrinth-*.json are trimmed real Modrinth responses; the CurseForge
# responses below are written by hand after the CurseForge API documentation.

BeforeAll {
	$root = Split-Path -Parent $PSScriptRoot
	foreach ($part in 'Common', 'Config', 'Releases', 'Modrinth', 'CurseForge', 'Catalog',
		'Selection', 'Dependencies', 'Download', 'Report') {
		. (Join-Path $root "src/$part.ps1")
	}
	Import-YamlModule

	$script:Root = $root
	$script:Requests = New-Object 'System.Collections.Generic.List[string]'
	$script:Routes = [ordered]@{}

	function Read-Fixture([string]$Name) {
		return [IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures/$Name")) | ConvertFrom-Json
	}

	# Answers a request from the first route whose pattern matches the URL.
	function Get-Route([string]$Uri) {
		$script:Requests.Add($Uri)
		foreach ($pattern in $script:Routes.Keys) {
			if ($Uri -match $pattern) {
				$answer = $script:Routes[$pattern]
				if ($answer -is [scriptblock]) { return & $answer $Uri }
				return $answer
			}
		}
		throw "unexpected request: $Uri"
	}

	function New-Version([string]$FileName, [string]$Sha1 = '', $Dependencies = @()) {
		return [pscustomobject]@{
			files        = @([pscustomobject]@{
					url      = "https://cdn.example/$FileName"
					filename = $FileName
					primary  = $true
					hashes   = [pscustomobject]@{ sha1 = $Sha1 }
				})
			dependencies = @($Dependencies)
		}
	}

	# Modrinth answers per project id; a project left out has no fitting version.
	function Set-ModrinthVersions([hashtable]$ByProject) {
		$script:Routes['modrinth\.com/v2/project/([^/]+)/version'] = {
			param($Uri)
			$null = $Uri -match 'project/([^/]+)/version'
			$versions = $ByProject[$Matches[1]]
			if ($null -eq $versions) { return , @() }
			return , @($versions)
		}.GetNewClosure()
	}

	function New-TestContext([string]$Build, [string]$Modules = '{}', [string]$Assets = '{}') {
		$dir = Join-Path $TestDrive ([guid]::NewGuid())
		New-Item -ItemType Directory -Path $dir | Out-Null
		Write-TextFile "$dir/build.yaml" $Build
		Write-TextFile "$dir/modules.yaml" $Modules
		Write-TextFile "$dir/assets.yaml" $Assets
		return New-BuildContext -BuildFile "$dir/build.yaml" -ModulesFile "$dir/modules.yaml" -AssetsFile "$dir/assets.yaml"
	}

	# assets.yaml text for modrinth mods whose id equals their key
	function New-Assets([string[]]$Mods, [string[]]$Packs = @()) {
		$lines = @('mods:')
		foreach ($mod in $Mods) { $lines += "  ${mod}: { name: $mod, source: modrinth, mod_id: $mod }" }
		$lines += 'resourcepacks:'
		foreach ($pack in $Packs) { $lines += "  ${pack}: { name: $pack, source: modrinth, mod_id: $pack }" }
		return $lines -join "`n"
	}
}

Describe 'mimobu' {
	BeforeEach {
		$script:Requests.Clear()
		$script:Routes.Clear()
		Mock Invoke-Api { Get-Route $Uri | ForEach-Object { $_ } }
		Mock Write-Host {}
		Mock Write-Progress {}
	}

	Describe 'Get-EffectiveLoader' {
		It 'looks up <loader> <version> as <expected>' -TestCases @(
			@{ loader = 'neoforge'; version = '1.20.1'; expected = 'forge' }
			@{ loader = 'NeoForge'; version = '1.20.1'; expected = 'forge' }
			@{ loader = 'neoforge'; version = '1.19.2'; expected = 'forge' }
			@{ loader = 'neoforge'; version = '1.20.4'; expected = 'neoforge' }
			@{ loader = 'neoforge'; version = '1.21.1'; expected = 'neoforge' }
			@{ loader = 'fabric'; version = '1.20.1'; expected = 'fabric' }
		) {
			Get-EffectiveLoader $loader $version | Should -Be $expected
		}
	}

	Describe 'Get-CurseForgeKey' {
		BeforeEach {
			$script:SavedKey = $env:CURSEFORGE_API_KEY
			Remove-Item Env:CURSEFORGE_API_KEY -ErrorAction SilentlyContinue
			$script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
			New-Item -ItemType Directory -Path $script:Dir | Out-Null
		}
		AfterEach {
			if ($script:SavedKey) { $env:CURSEFORGE_API_KEY = $script:SavedKey } else { Remove-Item Env:CURSEFORGE_API_KEY -ErrorAction SilentlyContinue }
		}

		It 'prefers the environment variable, then curseforge.key, then build.yaml' {
			$build = @{ cf_api_key = 'from-build' }
			(Get-CurseForgeKey "$script:Dir/build.yaml" $build).From | Should -Be 'build.yaml'
			Write-TextFile "$script:Dir/curseforge.key" "from-file`n"
			(Get-CurseForgeKey "$script:Dir/build.yaml" $build).Value | Should -Be 'from-file'
			$env:CURSEFORGE_API_KEY = 'from-env'
			(Get-CurseForgeKey "$script:Dir/build.yaml" $build).Value | Should -Be 'from-env'
		}

		It 'returns nothing when no key is anywhere' {
			Get-CurseForgeKey "$script:Dir/build.yaml" @{} | Should -BeNullOrEmpty
		}
	}

	Describe 'New-BuildContext' {
		It 'asks for quotes when YAML turned the version into a number' {
			{ New-TestContext "version: 1.20`nmodloader: forge" } | Should -Throw '*quotes*'
		}
	}

	Describe 'Module selection' {
		It 'enables a sub-module listed before the module it depends on' {
			Set-ModrinthVersions @{ base = New-Version 'base.jar'; extra = New-Version 'extra.jar' }
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge" @'
main_modules:
  create: { mods: [base] }
sub_modules:
  cannons: { depends_module: [create], mods: [extra] }
'@ (New-Assets base, extra)
			Select-Modules $ctx @('cannons', 'create')
			$ctx.Selection.mods.Keys | Should -Be @('base', 'extra')
			($ctx.Problems -join "`n") | Should -BeNullOrEmpty
		}

		It 'reports a sub-module whose module is not in the build' {
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge" @'
main_modules:
  create: { mods: [base] }
sub_modules:
  cannons: { depends_module: [create], mods: [extra] }
'@ (New-Assets base, extra)
			Select-Modules $ctx @('cannons')
			$ctx.Selection.mods.Count | Should -Be 0
			($ctx.Problems -join "`n") | Should -Match "module 'cannons' skipped: it needs create"
		}

		It 'accepts a module alias' {
			Set-ModrinthVersions @{ fps = New-Version 'fps.jar' }
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge" @'
main_modules:
  optimization: { aliases: [optimizaion], mods: [fps] }
'@ (New-Assets fps)
			Select-Modules $ctx @('optimizaion')
			$ctx.ActiveModules | Should -Contain 'optimization'
			$ctx.Selection.mods.Keys | Should -Contain 'fps'
		}

		It 'takes the first fitting variant of a platform mod listed in a module' {
			Set-ModrinthVersions @{ titles_neo = New-Version 'titles-neo.jar' }
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge" @'
platform_mods:
  titles: [titles_forge, titles_neo]
main_modules:
  dim: { platform_mods: [titles] }
'@ (New-Assets titles_forge, titles_neo)
			Select-Modules $ctx @('dim')
			$ctx.Selection.mods.Keys | Should -Be @('titles_neo')
			Test-Active $ctx 'titles' | Should -BeTrue
		}

		It 'reports unknown modules and mods missing from assets.yaml' {
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge" @'
main_modules:
  ui: { mods: [typo_mod] }
'@ (New-Assets @())
			Select-Modules $ctx @('ui', 'nonexistent')
			($ctx.Problems -join "`n") | Should -Match "'typo_mod' \(module ui\) is not in assets.yaml"
			($ctx.Problems -join "`n") | Should -Match "module 'nonexistent'"
		}

		It 'falls back to the newest file for a pinned entry without a fitting version' {
			$script:Routes['game_versions'] = , @()
			$script:Routes['project/pack/version$'] = , @(New-Version 'pack-old.zip')
			$ctx = New-TestContext "version: '1.21'`nmodloader: forge" @'
main_modules:
  look: { resourcepacks: [ { pack: { pinned: true } } ] }
'@ (New-Assets -Mods @() -Packs pack)
			Select-Modules $ctx @('look')
			$ctx.Selection.resourcepacks['pack'].Release.File.FileName | Should -Be 'pack-old.zip'
		}
	}

	Describe 'Integrations' {
		BeforeEach {
			$script:Modules = @'
platform_mods:
  fortresses: [fortresses_forge, fortresses_neo]
main_modules:
  boss: { mods: [cataclysm] }
  yung: { platform_mods: [fortresses] }
  food: { mods: [delight] }
  mobs: { mods: [mobs] }
integrations:
  one2other:
    delight:
      mobs_delight: mobs
  manual:
    cataclysm_fortress_compat:
      depends_mods_compound:
        and:
          cataclysm:
          or:
            - fortresses_neo
            - fortresses_forge
    mobs_delight_extra:
      depends_mods: [mobs_delight]
'@
			$script:Assets = New-Assets cataclysm, fortresses_forge, fortresses_neo, delight, mobs, mobs_delight, cataclysm_fortress_compat, mobs_delight_extra
			Set-ModrinthVersions @{
				cataclysm = New-Version 'c.jar'; fortresses_forge = New-Version 'f.jar'; delight = New-Version 'd.jar'
				mobs = New-Version 'm.jar'; mobs_delight = New-Version 'md.jar'; cataclysm_fortress_compat = New-Version 'cf.jar'
				mobs_delight_extra = New-Version 'mde.jar'
			}
		}

		It 'adds a compound integration when cataclysm and a fortress variant are active' {
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge`nallow_integrations: true" $script:Modules $script:Assets
			Select-Modules $ctx @('boss', 'yung')
			Add-Integrations $ctx
			$ctx.Selection.mods.Keys | Should -Contain 'cataclysm_fortress_compat'
		}

		It 'leaves the compound integration out without a fortress variant' {
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge`nallow_integrations: true" $script:Modules $script:Assets
			Select-Modules $ctx @('boss')
			Add-Integrations $ctx
			$ctx.Selection.mods.Keys | Should -Not -Contain 'cataclysm_fortress_compat'
		}

		It 'adds one2other integrations, and integrations that need them' {
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge`nallow_integrations: true" $script:Modules $script:Assets
			Select-Modules $ctx @('food', 'mobs')
			Add-Integrations $ctx
			$ctx.Selection.mods.Keys | Should -Contain 'mobs_delight'
			$ctx.Selection.mods.Keys | Should -Contain 'mobs_delight_extra'
		}

		It 'adds nothing when integrations are off' {
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge`nallow_integrations: false" $script:Modules $script:Assets
			Select-Modules $ctx @('food', 'mobs')
			Add-Integrations $ctx
			$ctx.Selection.mods.Keys | Should -Not -Contain 'mobs_delight'
		}

		It 'reports a one2other entry that is not a map' {
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge`nallow_integrations: true" @'
integrations:
  one2other:
    village:
      compat_a
      compat_b
'@
			Add-Integrations $ctx
			($ctx.Problems -join "`n") | Should -Match 'one2other.village must map'
		}
	}

	Describe 'Modrinth lookups' {
		It 'asks for resource packs without a loader filter' {
			$script:Routes['project/50dA9Sha/version'] = , @(Read-Fixture 'modrinth-fresh-animations-versions.json')
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: neoforge" '{}' @'
resourcepacks:
  fresh_animations: { name: Fresh Animations, source: modrinth, mod_id: 50dA9Sha }
'@
			Add-Asset $ctx 'resourcepacks' 'fresh_animations' 'test' | Should -BeTrue
			$script:Requests[0] | Should -Not -Match 'loaders'
			$script:Requests[0] | Should -Match 'game_versions'
		}

		It 'asks for mods with the effective loader' {
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: neoforge" '{}' (New-Assets solo)
			Set-ModrinthVersions @{}
			Add-Asset $ctx 'mods' 'solo' 'test' | Should -BeFalse
			[uri]::UnescapeDataString($script:Requests[0]) | Should -Match 'loaders=\["forge"\]'
			$ctx.Skipped[0].Reason | Should -Be 'no version for forge 1.20.1'
		}

		It 'adds a dependency missing from assets.yaml under the key of its name' {
			$script:Routes['project/JtifUr64/version'] = , @(Read-Fixture 'modrinth-travelers-titles-versions.json')
			$script:Routes['project/Ua7DFN59/version'] = , @(New-Version 'yungs-api.jar')
			$script:Routes['project/Ua7DFN59$'] = Read-Fixture 'modrinth-yung-api-project.json'
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge" '{}' @'
mods:
  traveler_s_titles: { name: "Traveler's Titles", source: modrinth, mod_id: JtifUr64 }
'@
			Add-Asset $ctx 'mods' 'traveler_s_titles' 'test' | Should -BeTrue
			Add-Dependencies $ctx
			$ctx.Selection.mods.Keys | Should -Contain 'yung_s_api'
			$ctx.Selection.mods['yung_s_api'].Via | Should -Be 'dependency of traveler_s_titles'
			$ctx.Discovered.Keys | Should -Be @('yung_s_api')
		}

		It 'uses the existing entry when a found dependency has the same name' {
			$script:Routes['project/JtifUr64/version'] = , @(Read-Fixture 'modrinth-travelers-titles-versions.json')
			$script:Routes['project/Ua7DFN59$'] = Read-Fixture 'modrinth-yung-api-project.json'
			$script:Routes['curseforge\.com/v1/mods/421649/files'] = @{ data = @(@{ downloadUrl = 'https://cf.example/api.jar'; fileName = 'api.jar'; hashes = @(); dependencies = @() }) }
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge`ncf_api_key: k" '{}' @'
mods:
  traveler_s_titles: { name: "Traveler's Titles", source: modrinth, mod_id: JtifUr64 }
  yung_s_api: { name: "YUNG's API", source: curseforge, mod_id: "421649" }
'@
			[void](Add-Asset $ctx 'mods' 'traveler_s_titles' 'test')
			Add-Dependencies $ctx
			$ctx.Selection.mods['yung_s_api'].Release.File.FileName | Should -Be 'api.jar'
			$ctx.Discovered.Count | Should -Be 0
		}

		It 'finds the project of a dependency that names only a version' {
			$dependency = [pscustomobject]@{ project_id = $null; version_id = 'v123'; dependency_type = 'required' }
			Set-ModrinthVersions @{ app = New-Version 'app.jar' -Dependencies @($dependency); lib = New-Version 'lib.jar' }
			$script:Routes['v2/version/v123$'] = [pscustomobject]@{ project_id = 'lib' }
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge" '{}' (New-Assets app, lib)
			[void](Add-Asset $ctx 'mods' 'app' 'test')
			Add-Dependencies $ctx
			$ctx.Selection.mods.Keys | Should -Contain 'lib'
		}
	}

	Describe 'CurseForge lookups' {
		It 'reads the sha1 and the required and optional dependencies' {
			$script:Routes['mods/100/files'] = @{ data = @(@{
						downloadUrl = 'https://cf.example/a.jar'; fileName = 'a.jar'
						hashes = @(@{ value = 'md5value'; algo = 2 }, @{ value = 'SHA1VALUE'; algo = 1 })
						dependencies = @(@{ modId = 200; relationType = 3 }, @{ modId = 300; relationType = 2 }, @{ modId = 400; relationType = 5 })
					})
			}
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge`ncf_api_key: k"
			$release = Find-CurseForgeRelease $ctx 'mods' '100' $true
			$release.File.Sha1 | Should -Be 'SHA1VALUE'
			$release.Dependencies.Count | Should -Be 2
			($release.Dependencies | Where-Object Required).Id | Should -Be '200'
			$script:Requests[0] | Should -Match 'modLoaderType=1'
		}

		It 'marks a blocked file for manual download when Modrinth has no copy' {
			$script:Routes['mods/100/files'] = @{ data = @(@{ id = 555; downloadUrl = $null; fileName = 'blocked.jar'; hashes = @(); dependencies = @() }) }
			$script:Routes['curseforge\.com/v1/mods/100$'] = @{ data = @{ name = 'Blocked'; slug = 'blocked'; authors = @(@{ name = 'someone' }); links = @{ websiteUrl = 'https://www.curseforge.com/minecraft/mc-mods/blocked' } } }
			$script:Routes['v2/search'] = @{ hits = @() }
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge`ncf_api_key: k"
			$file = (Find-CurseForgeRelease $ctx 'mods' '100' $true).File
			$file.Url | Should -BeNullOrEmpty
			$file.Page | Should -Be 'https://www.curseforge.com/minecraft/mc-mods/blocked/files/555'
		}

		It 'fails the lookup without a key' {
			$ctx = New-TestContext "version: '1.20.1'`nmodloader: forge" '{}' @'
mods:
  cf_mod: { name: CF Mod, source: curseforge, mod_id: "1" }
'@
			Add-Asset $ctx 'mods' 'cf_mod' 'test' | Should -BeFalse
			$ctx.Skipped[0].Failed | Should -BeTrue
			$ctx.Skipped[0].Reason | Should -Match 'no CurseForge API key'
		}
	}

	Describe 'Sync-Files' {
		BeforeAll {
			$script:HelloSha1 = 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d'

			function Select-Fake([string]$Key, [string]$FileName, [string]$Sha1 = $script:HelloSha1, [string]$Url = 'https://cdn.example/x') {
				$file = @{ Url = $Url; FileName = $FileName; Sha1 = $Sha1; Page = 'https://page.example' }
				$script:Ctx.Selection.mods[$Key] = @{ Via = 'test'; Pinned = $false; Release = (New-Release -File $file) }
			}
		}
		BeforeEach {
			Mock Save-Url { [IO.File]::WriteAllText($Path, 'hello') }
			$script:Out = Join-Path $TestDrive ([guid]::NewGuid())
			$script:Ctx = New-TestContext "version: '1.20.1'`nmodloader: forge"
		}

		It 'downloads, checks the hash and records the file' {
			Select-Fake 'a' 'a.jar'
			$results = Sync-Files $script:Ctx $script:Out $false $false
			$results[0].Status | Should -Be 'downloaded'
			Test-Path "$script:Out/mods/a.jar" | Should -BeTrue
			(Read-FileManifest "$script:Out/.mimobu-files.json")['mods/a.jar'].Key | Should -Be 'a'
		}

		It 'leaves nothing behind when the hash does not match' {
			Select-Fake 'a' 'a.jar' -Sha1 '0000'
			$results = Sync-Files $script:Ctx $script:Out $false $false
			$results[0].Status | Should -Be 'failed'
			Get-ChildItem "$script:Out/mods" | Should -BeNullOrEmpty
		}

		It 'does not download a file that is already there and intact' {
			Select-Fake 'a' 'a.jar'
			[void](Sync-Files $script:Ctx $script:Out $false $false)
			$results = Sync-Files $script:Ctx $script:Out $false $false
			$results[0].Status | Should -Be 'current'
			Should -Invoke Save-Url -Times 1 -Exactly
		}

		It 'moves files that left the build to .old but keeps those whose lookup failed' {
			Select-Fake 'a' 'a.jar'
			Select-Fake 'b' 'b.jar'
			Select-Fake 'c' 'c.jar'
			[void](Sync-Files $script:Ctx $script:Out $false $false)

			$script:Ctx = New-TestContext "version: '1.20.1'`nmodloader: forge"
			Select-Fake 'a' 'a.jar'
			Add-Skip $script:Ctx 'mods' 'c' 'network down' 'test' $true
			$results = Sync-Files $script:Ctx $script:Out $false $false

			($results | Where-Object Key -eq 'b').Status | Should -Be 'moved'
			Test-Path "$script:Out/.old/mods/b.jar" | Should -BeTrue
			Test-Path "$script:Out/mods/c.jar" | Should -BeTrue
			(Read-FileManifest "$script:Out/.mimobu-files.json").Keys | Sort-Object | Should -Be @('mods/a.jar', 'mods/c.jar')
		}

		It 'keeps the old file of a mod whose new file must be fetched by hand' {
			Select-Fake 'a' 'a-1.jar'
			[void](Sync-Files $script:Ctx $script:Out $false $false)
			$script:Ctx = New-TestContext "version: '1.20.1'`nmodloader: forge"
			Select-Fake 'a' 'a-2.jar' -Url ''
			$results = Sync-Files $script:Ctx $script:Out $false $false
			$results[0].Status | Should -Be 'manual'
			$results[0].Detail | Should -Be 'https://page.example'
			Test-Path "$script:Out/mods/a-1.jar" | Should -BeTrue
		}

		It 'writes nothing in a dry run' {
			Select-Fake 'a' 'a.jar'
			$results = Sync-Files $script:Ctx $script:Out $false $true
			$results[0].Status | Should -Be 'new'
			Test-Path $script:Out | Should -BeFalse
		}
	}

	Describe 'Save-AssetCatalog' {
		It 'keeps every entry of the real assets.yaml and saves the same text twice' {
			$path = Join-Path $TestDrive 'assets.yaml'
			Copy-Item (Join-Path $script:Root 'assets.yaml') $path
			$original = Read-YamlFile $path
			Save-AssetCatalog $original $path
			$first = [IO.File]::ReadAllText($path)
			Save-AssetCatalog (Read-YamlFile $path) $path
			[IO.File]::ReadAllText($path) | Should -BeExactly $first

			$saved = Read-YamlFile $path
			$saved.mods.Count | Should -Be $original.mods.Count
			$saved.resourcepacks.Count | Should -Be $original.resourcepacks.Count
			$saved.mods['alex_s_mobs'].mod_id | Should -Be '426558'
			Test-Path "$path.bak" | Should -BeTrue
		}
	}

	Describe 'prismAssetDumper.ps1' {
		It 'adds installed mods and keeps entries already listed' {
			$index = Join-Path $TestDrive 'instances/pack/minecraft/mods/.index'
			New-Item -ItemType Directory -Path $index -Force | Out-Null
			Write-TextFile "$index/a.pw.toml" @'
filename = "a.jar"
name = "Alpha Mod"
side = "both"

[update]
[update.curseforge]
file-id = 111
project-id = 222
'@
			Write-TextFile "$index/b.pw.toml" @'
name = 'Beta Mod'

[update.modrinth]
mod-id = 'BeTa1234'
version = 'v1'
'@
			$assets = Join-Path $TestDrive 'assets.yaml'
			Write-TextFile $assets "mods:`n  beta_mod: { name: Beta Mod, source: curseforge, mod_id: '999' }`nresourcepacks: {}"

			& (Join-Path $script:Root 'prismAssetDumper.ps1') -InstancesDir (Join-Path $TestDrive 'instances') -AssetsFile $assets

			$saved = Read-YamlFile $assets
			$saved.mods['alpha_mod'].source | Should -Be 'curseforge'
			$saved.mods['alpha_mod'].mod_id | Should -Be '222'
			$saved.mods['beta_mod'].mod_id | Should -Be '999'
		}
	}
}
