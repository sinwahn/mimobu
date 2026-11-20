# Which assets the build takes: modules, platform variants, additions, integrations.

function Resolve-ModuleName($Ctx, [string]$Name) {
	$canonical = Get-MapValue $Ctx.ModuleAliases $Name
	if ($canonical) { return $canonical }
	return $Name
}

# A module list entry is a key, or { key: { pinned: true } }.
function ConvertFrom-ModuleEntry($Entry) {
	if ($Entry -is [string]) { return @{ Key = $Entry; Pinned = $false } }
	if ($Entry -is [System.Collections.IDictionary] -and $Entry.Count -eq 1) {
		$key = @($Entry.Keys)[0]
		$flags = $Entry[$key]
		$pinned = ($flags -is [System.Collections.IDictionary]) -and ($flags['pinned'] -eq $true)
		return @{ Key = "$key"; Pinned = $pinned }
	}
	return $null
}

# True when the mod, or any variant of a platform mod, is selected.
function Test-Active($Ctx, [string]$Key) {
	if ($Ctx.Selection.mods.Contains($Key)) { return $true }
	foreach ($variant in @(Get-Items (Get-MapValue $Ctx.Modules.platform_mods $Key))) {
		if ($Ctx.Selection.mods.Contains($variant)) { return $true }
	}
	return $false
}

# Selects an asset if it has a fitting version. $Via says why it was asked for.
function Add-Asset($Ctx, [string]$Kind, [string]$Key, [string]$Via, [bool]$Pinned = $false) {
	if ($Kind -eq 'mods' -and (Test-MapKey $Ctx.Modules.platform_mods $Key)) {
		return Add-PlatformMod $Ctx $Key $Via
	}
	if ($Ctx.Selection[$Kind].Contains($Key)) { return $true }
	if (-not (Test-MapKey $Ctx.Assets[$Kind] $Key)) {
		Add-Skip $Ctx $Kind $Key 'not in assets.yaml' $Via
		Add-Problem $Ctx "'$Key' ($Via) is not in assets.yaml"
		return $false
	}

	$release = Get-Release $Ctx $Kind $Key $Pinned
	if ($null -eq $release.File) {
		Add-Skip $Ctx $Kind $Key $release.Reason $Via $release.Failed
		return $false
	}
	$Ctx.Selection[$Kind][$Key] = @{ Via = $Via; Pinned = $Pinned; Release = $release }
	Write-Verbose "take $Kind/$Key ($Via)"
	return $true
}

# A platform mod names variants of one mod (a backport, another loader's build);
# the first variant with a fitting version is taken.
function Add-PlatformMod($Ctx, [string]$Name, [string]$Via) {
	$variants = @(Get-Items $Ctx.Modules.platform_mods[$Name])
	foreach ($variant in $variants) {
		if ($Ctx.Selection.mods.Contains($variant)) { return $true }
	}
	$failure = $null
	foreach ($variant in $variants) {
		if (-not (Test-MapKey $Ctx.Assets.mods $variant)) {
			Add-Problem $Ctx "platform mod '$Name': variant '$variant' is not in assets.yaml"
			continue
		}
		$release = Get-Release $Ctx 'mods' $variant
		if ($null -ne $release.File) {
			$Ctx.Selection.mods[$variant] = @{ Via = "$Via, variant of $Name"; Pinned = $false; Release = $release }
			Write-Verbose "take mods/$variant (variant of $Name)"
			return $true
		}
		if ($release.Failed) { $failure = $release.Reason }
	}
	if ($failure) {
		# a variant could not be checked, so "nothing fits" would be a guess
		Add-Skip $Ctx 'mods' $Name $failure $Via $true
	} else {
		Add-Skip $Ctx 'mods' $Name "no variant fits $($Ctx.Loader) $($Ctx.GameVersion)" $Via
	}
	return $false
}

function Enable-Module($Ctx, [string]$Name, $Definition) {
	if (-not $Ctx.ActiveModules.Add($Name)) { return }
	Write-Verbose "module $Name"
	$via = "module $Name"
	$mods = @(Get-Items (Get-MapValue $Definition 'mods')) + @(Get-Items (Get-MapValue $Definition 'platform_mods'))
	foreach ($kind in 'mods', 'resourcepacks') {
		$entries = if ($kind -eq 'mods') { $mods } else { @(Get-Items (Get-MapValue $Definition 'resourcepacks')) }
		foreach ($raw in $entries) {
			$entry = ConvertFrom-ModuleEntry $raw
			if ($null -eq $entry) {
				Add-Problem $Ctx "module '$Name' has an entry that is neither a name nor { name: { pinned: true } }"
				continue
			}
			[void](Add-Asset $Ctx $kind $entry.Key $via $entry.Pinned)
		}
	}
}

# Main modules are enabled as listed; a sub-module once every module it depends
# on is enabled, wherever it stands in the list.
function Select-Modules($Ctx, $Requested) {
	$mainModules = $Ctx.Modules.main_modules
	$subModules = $Ctx.Modules.sub_modules
	$pending = New-Object 'System.Collections.Generic.List[string]'

	foreach ($raw in @(Get-Items $Requested)) {
		$name = Resolve-ModuleName $Ctx "$raw"
		if (Test-MapKey $mainModules $name) {
			Enable-Module $Ctx $name $mainModules[$name]
		} elseif (Test-MapKey $subModules $name) {
			if (-not $pending.Contains($name)) { $pending.Add($name) }
		} else {
			Add-Problem $Ctx "build.yaml lists module '$raw', which modules.yaml does not define"
		}
	}

	do {
		$progress = $false
		foreach ($name in @($pending)) {
			if ((Get-MissingModules $Ctx $subModules[$name]).Count -eq 0) {
				Enable-Module $Ctx $name $subModules[$name]
				[void]$pending.Remove($name)
				$progress = $true
			}
		}
	} while ($progress)

	foreach ($name in $pending) {
		$missing = Get-MissingModules $Ctx $subModules[$name]
		Add-Problem $Ctx "module '$name' skipped: it needs $($missing -join ', '), which the build does not enable"
	}
}

function Get-MissingModules($Ctx, $Definition) {
	$required = @(Get-Items (Get-MapValue $Definition 'depends_module')) | ForEach-Object { Resolve-ModuleName $Ctx "$_" }
	return @($required | Where-Object { -not $Ctx.ActiveModules.Contains($_) })
}

function Add-Additions($Ctx) {
	$addition = Get-MapValue $Ctx.Build 'addition'
	foreach ($mod in @(Get-Items (Get-MapValue $addition 'mods'))) {
		[void](Add-Asset $Ctx 'mods' "$mod" 'build.yaml addition')
	}
	$packages = @(Get-Items (Get-MapValue $addition 'packages'))
	if ($packages.Count -gt 0) {
		Add-Problem $Ctx "addition.packages is not supported yet, ignored: $($packages -join ', ')"
	}
}

# ---------------------------------------------------------------- integrations

# Adds integration mods whose conditions hold, repeating while new mods arrive,
# since an integration can itself enable another.
function Add-Integrations($Ctx) {
	$integrations = Get-MapValue $Ctx.Modules 'integrations'
	if (-not $Ctx.AllowIntegrations -or $null -eq $integrations) { return }
	do {
		$before = $Ctx.Selection.mods.Count
		Add-OneToOtherIntegrations $Ctx (Get-MapValue $integrations 'one2other')
		Add-ManualIntegrations $Ctx (Get-MapValue $integrations 'manual')
	} while ($Ctx.Selection.mods.Count -gt $before)
}

# one2other: host mod -> { integration mod: the other mod it needs }.
function Add-OneToOtherIntegrations($Ctx, $Rules) {
	if ($null -eq $Rules) { return }
	foreach ($hostMod in @($Rules.Keys)) {
		$pairs = $Rules[$hostMod]
		if ($pairs -isnot [System.Collections.IDictionary]) {
			Add-Problem $Ctx "integrations.one2other.$hostMod must map each integration mod to the mod it needs"
			continue
		}
		if (-not (Test-Active $Ctx $hostMod)) { continue }
		foreach ($integration in @($pairs.Keys)) {
			$other = $pairs[$integration]
			if (Test-Active $Ctx $other) {
				[void](Add-Asset $Ctx 'mods' $integration "integration of $hostMod + $other")
			}
		}
	}
}

# manual: integration mod -> { depends_mods: [...] } or { depends_mods_compound: condition },
# with optional or_samecondition: other mods taken under the same condition.
function Add-ManualIntegrations($Ctx, $Rules) {
	if ($null -eq $Rules) { return }
	foreach ($integration in @($Rules.Keys)) {
		$rule = $Rules[$integration]
		if (Test-MapKey $rule 'depends_mods') {
			$required = @(Get-Items $rule.depends_mods)
			$met = @($required | Where-Object { -not (Test-Active $Ctx $_) }).Count -eq 0
			$via = "integration of $($required -join ' + ')"
		} elseif (Test-MapKey $rule 'depends_mods_compound') {
			$met = Test-Condition $Ctx $rule.depends_mods_compound
			$via = 'integration (compound condition)'
		} else {
			Add-Problem $Ctx "integrations.manual.$integration has neither depends_mods nor depends_mods_compound"
			continue
		}
		if (-not $met) { continue }
		[void](Add-Asset $Ctx 'mods' $integration $via)
		foreach ($alias in @(Get-Items (Get-MapValue $rule 'or_samecondition'))) {
			[void](Add-Asset $Ctx 'mods' "$alias" $via)
		}
	}
}

# A condition is a mod name, a list (all must hold), or a map. In a map, the keys
# "and" and "or" are groups; any other key is a mod that must be active, and its
# value, when it is a map, is a further condition that must hold too.
#   and: { modA:, or: [modB, modC] }   ->  modA and (modB or modC)
function Test-Condition($Ctx, $Node) {
	if ($null -eq $Node) { return $true }
	if ($Node -is [string]) { return Test-Active $Ctx $Node }
	if ($Node -is [System.Collections.IDictionary]) {
		foreach ($key in @($Node.Keys)) {
			$value = $Node[$key]
			$holds = switch ($key) {
				'and' { Test-Condition $Ctx $value }
				'or' { Test-AnyCondition $Ctx $value }
				default { (Test-Active $Ctx $key) -and (Test-Condition $Ctx $value) }
			}
			if (-not $holds) { return $false }
		}
		return $true
	}
	foreach ($item in @(Get-Items $Node)) {
		if (-not (Test-Condition $Ctx $item)) { return $false }
	}
	return $true
}

function Test-AnyCondition($Ctx, $Node) {
	if ($Node -is [System.Collections.IDictionary]) {
		foreach ($key in @($Node.Keys)) {
			if (Test-Condition $Ctx @{ $key = $Node[$key] }) { return $true }
		}
		return $false
	}
	foreach ($item in @(Get-Items $Node)) {
		if (Test-Condition $Ctx $item) { return $true }
	}
	return $false
}
