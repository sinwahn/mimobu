# Shared helpers: console output, HTTP with retries, YAML files, map access.

function Write-Step([string]$Text) {
	Write-Host "`n== $Text" -ForegroundColor Cyan
}

function Write-Info([string]$Text, [string]$Color = 'Gray') {
	Write-Host "   $Text" -ForegroundColor $Color
}

function Initialize-Environment {
	# Windows PowerShell 5.1 does not enable TLS 1.2 by default; both APIs require it.
	[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
	Import-YamlModule
}

function Import-YamlModule {
	if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
		Write-Info 'Installing powershell-yaml for the current user...' Yellow
		Install-Module -Name powershell-yaml -Scope CurrentUser -Force
	}
	Import-Module powershell-yaml
}

# ---------------------------------------------------------------- maps and lists

function Test-MapKey($Map, [string]$Key) {
	return ($null -ne $Map) -and ($Map -is [System.Collections.IDictionary]) -and $Map.Contains($Key)
}

function Get-MapValue($Map, [string]$Key) {
	if (Test-MapKey $Map $Key) { return $Map[$Key] }
	return $null
}

# Emits the items of a YAML list one by one; a missing list emits nothing and a
# single scalar emits itself. Callers wrap the call in @() to get an array.
function Get-Items($Value) {
	if ($null -eq $Value) { return }
	$Value | Where-Object { $null -ne $_ }
}

# The key an asset gets from its display name: "Alex's Mobs" -> "alex_s_mobs".
function ConvertTo-AssetKey([string]$Name) {
	return ($Name.ToLower() -replace '[^a-z0-9]+', '_').Trim('_')
}

# ---------------------------------------------------------------- files

function Get-FullPath([string]$Path) {
	return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-YamlFile([string]$Path) {
	$full = Get-FullPath $Path
	if (-not (Test-Path -LiteralPath $full)) { throw "File not found: $full" }
	try {
		$data = ConvertFrom-Yaml ([IO.File]::ReadAllText($full))
	} catch {
		throw "Cannot parse ${full}: $($_.Exception.Message)"
	}
	if ($null -eq $data) { return @{} }
	return $data
}

function Write-TextFile([string]$Path, [string]$Text) {
	$normalized = ($Text -replace "`r`n", "`n").TrimEnd("`n") + "`n"
	[IO.File]::WriteAllText((Get-FullPath $Path), $normalized, (New-Object Text.UTF8Encoding $false))
}

function Get-Sha1([string]$Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant()
}

# ---------------------------------------------------------------- HTTP

function Get-HttpStatus($ErrorRecord) {
	$response = $ErrorRecord.Exception.Response
	if ($null -eq $response) { return 0 }
	return [int]$response.StatusCode
}

# Runs $Action, retrying rate limits (429) and server errors (5xx) with backoff.
function Invoke-WithRetry([scriptblock]$Action, [int]$Attempts = 3) {
	for ($attempt = 1; ; $attempt++) {
		try {
			return & $Action
		} catch {
			$status = Get-HttpStatus $_
			$retryable = ($status -eq 429) -or ($status -ge 500)
			if (-not $retryable -or $attempt -ge $Attempts) { throw }
			Start-Sleep -Seconds ([math]::Pow(2, $attempt))
		}
	}
}

# The single point where API requests leave the script; tests replace it.
# A JSON array comes out as its items (an empty one as nothing), so callers
# collect the result with @().
function Invoke-Api([string]$Uri, [hashtable]$Headers = @{}) {
	Write-Verbose "GET $Uri"
	Invoke-WithRetry { Invoke-RestMethod -Uri $Uri -Headers $Headers -UseBasicParsing -ErrorAction Stop } |
		ForEach-Object { $_ }
}

function Save-Url([string]$Uri, [string]$Path) {
	$ProgressPreference = 'SilentlyContinue'  # the progress bar makes 5.1 downloads many times slower
	Invoke-WithRetry { Invoke-WebRequest -Uri $Uri -OutFile $Path -UseBasicParsing -ErrorAction Stop } | Out-Null
}
