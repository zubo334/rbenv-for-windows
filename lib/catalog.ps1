# RubyInstaller release catalog

$RBENV_CATALOG_API = "https://api.github.com/repos/oneclick/rubyinstaller2/releases"
$RBENV_CATALOG_CACHE_SCHEMA = 1
$RBENV_CATALOG_CACHE_TTL_HOURS = 24
$RBENV_CATALOG_PER_PAGE = 100


function get_catalog_cache_path {
    return "$env:RBENV_ROOT\cache\remote-versions.json"
}


function sort_catalog_entries($entries) {
    @($entries) | Sort-Object -Property `
        @{ Expression = { [int](($_.version -split '[.-]')[0]) }; Descending = $true }, `
        @{ Expression = { [int](($_.version -split '[.-]')[1]) }; Descending = $true }, `
        @{ Expression = { [int](($_.version -split '[.-]')[2]) }; Descending = $true }, `
        @{ Expression = { [int](($_.version -split '[.-]')[3]) }; Descending = $true }
}


function parse_releases_json($json_text) {
    try {
        $decoded = $json_text | ConvertFrom-Json
        $releases = @($decoded)
    } catch {
        return $null
    }

    $entries = @()

    foreach ($release in $releases) {
        if ($release.draft -or $release.prerelease) {
            continue
        }

        $tag = [string] $release.tag_name
        if ($tag -notmatch '^rubyinstaller-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)$') {
            continue
        }

        $version = $Matches[1]
        $archive_name = "rubyinstaller-$version-x64.7z"
        $devkit_name = "rubyinstaller-devkit-$version-x64.exe"
        $asset_names = @($release.assets | ForEach-Object { [string] $_.name })

        if ($asset_names -notcontains $archive_name) {
            continue
        }

        $entries += [PSCustomObject] @{
            version = $version
            tag = $tag
            x64_7z = $true
            devkit_x64_exe = ($asset_names -contains $devkit_name)
        }
    }

    return [PSCustomObject] @{
        release_count = $releases.Count
        entries = @($entries)
    }
}


function fetch_github_releases_page($page) {
    $url = "$RBENV_CATALOG_API`?per_page=$RBENV_CATALOG_PER_PAGE&page=$page"

    $json = & curl.exe -fsSL `
        --connect-timeout 5 `
        --max-time 10 `
        -H "Accept: application/vnd.github+json" `
        -H "X-GitHub-Api-Version: 2022-11-28" `
        -H "User-Agent: rbenv-for-windows" `
        $url 2>$null

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ($json -join "`n")
}


function fetch_remote_catalog {
    $script:RBENV_CATALOG_FETCH_ATTEMPTED = $true

    $entries = @()
    $page = 1

    while ($page -le 20) {
        $json = fetch_github_releases_page $page
        if ($null -eq $json) {
            return $null
        }

        $parsed = parse_releases_json $json
        if ($null -eq $parsed) {
            return $null
        }

        $entries += @($parsed.entries)

        if ($parsed.release_count -lt $RBENV_CATALOG_PER_PAGE) {
            break
        }

        $page++
    }

    if ($page -gt 20 -or $entries.Count -eq 0) {
        return $null
    }

    return [PSCustomObject] @{
        schema_version = $RBENV_CATALOG_CACHE_SCHEMA
        fetched_at = [DateTimeOffset]::UtcNow.ToString('o')
        source = 'github-api'
        versions = @(sort_catalog_entries $entries)
    }
}


function read_catalog_cache {
    $path = get_catalog_cache_path
    if (-not (Test-Path $path)) {
        return $null
    }

    try {
        $catalog = Get-Content $path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }

    if ($catalog.schema_version -ne $RBENV_CATALOG_CACHE_SCHEMA) {
        return $null
    }

    $entries = @()
    foreach ($entry in @($catalog.versions)) {
        $version = [string] $entry.version
        if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$') {
            return $null
        }

        $tag = [string] $entry.tag
        if ([string]::IsNullOrWhiteSpace($tag)) {
            $tag = "RubyInstaller-$version"
        }

        $entries += [PSCustomObject] @{
            version = $version
            tag = $tag
            x64_7z = [bool] $entry.x64_7z
            devkit_x64_exe = [bool] $entry.devkit_x64_exe
        }
    }

    if ($entries.Count -eq 0) {
        return $null
    }

    return [PSCustomObject] @{
        schema_version = $RBENV_CATALOG_CACHE_SCHEMA
        fetched_at = [string] $catalog.fetched_at
        source = [string] $catalog.source
        versions = @(sort_catalog_entries $entries)
    }
}


function catalog_cache_fresh($catalog) {
    try {
        $fetched_at = [DateTimeOffset]::Parse(
            $catalog.fetched_at,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        return $false
    }

    $age = [DateTimeOffset]::UtcNow - $fetched_at.ToUniversalTime()
    return $age.TotalHours -lt $RBENV_CATALOG_CACHE_TTL_HOURS
}


function write_catalog_cache($catalog) {
    $path = get_catalog_cache_path
    $cache_dir = Split-Path $path -Parent
    $temp_path = "$path.$PID.tmp"

    try {
        ensure_path $cache_dir | Out-Null

        $json = $catalog | ConvertTo-Json -Depth 4
        $encoding = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($temp_path, $json, $encoding)

        Move-Item -LiteralPath $temp_path -Destination $path -Force -ErrorAction Stop

        return $true
    } catch {
        if (Test-Path $temp_path) {
            Remove-Item $temp_path -Force
        }
        return $false
    }
}


function load_bundled_catalog {
    $entries = @()
    $versions_path = "$PSScriptRoot\..\share\versions.txt"

    foreach ($version in @(Get-Content $versions_path)) {
        if ($version -eq 'head') {
            continue
        }
        if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$') {
            continue
        }

        $entries += [PSCustomObject] @{
            version = $version
            tag = "RubyInstaller-$version"
            x64_7z = $true
            devkit_x64_exe = $true
        }
    }

    return [PSCustomObject] @{
        schema_version = $RBENV_CATALOG_CACHE_SCHEMA
        fetched_at = $null
        source = 'bundled'
        versions = @(sort_catalog_entries $entries)
    }
}


function get_version_catalog {
    $cached = read_catalog_cache
    if ($null -ne $cached -and (catalog_cache_fresh $cached)) {
        return $cached
    }

    $remote = fetch_remote_catalog
    if ($null -ne $remote) {
        write_catalog_cache $remote | Out-Null
        return $remote
    }

    if ($null -ne $cached) {
        return $cached
    }

    return load_bundled_catalog
}


function get_remote_versions_with_devkit {
    $catalog = get_version_catalog
    @($catalog.versions | Where-Object {
        $_.devkit_x64_exe
    } | ForEach-Object {
        $_.version
    })
}


# Segment-aware match: '3.1' matches 3.1.x-y but not 3.10.x-y.
# The catalog is sorted descending, so the first match is the newest.
function find_catalog_version($catalog, $ver) {
    foreach ($entry in @($catalog.versions)) {
        $full = [string] $entry.version
        if ($full -eq $ver -or
            $full.StartsWith("$ver.") -or
            $full.StartsWith("$ver-")) {
            return $full
        }
    }
    return $null
}


function catalog_tag_for_version($version) {
    $catalog = get_version_catalog
    foreach ($entry in @($catalog.versions)) {
        if ($entry.version -eq $version) {
            return [string] $entry.tag
        }
    }
    return $null
}


# $kind: '7z' or 'devkit'
function build_download_url($version, $kind) {
    if ($version -eq 'head') {
        return "https://github.com/oneclick/rubyinstaller2/releases/download/rubyinstaller-head/rubyinstaller-head-x64.7z"
    }

    . $PSScriptRoot\..\share\mirrors.ps1

    $mir = $env:RBENV_USE_MIRROR
    if ($mir) {
        if ($mir -match '^https?://') { $site_url = $mir.TrimEnd('/') }
        else { $site_url = $RBENV_MIRRORS["$mir"] }
    } else {
        $site_url = $RBENV_MIRRORS['Default']
    }

    # Old releases use lowercase tags; URLs are case-sensitive
    $tag = catalog_tag_for_version $version
    if ($tag) {
        $site_url = $site_url -replace 'RubyInstaller-<version>', $tag
    }
    $site_url = $site_url -replace '<version>', $version

    if ($kind -eq 'devkit') {
        return "$site_url/rubyinstaller-devkit-$version-x64.exe"
    }
    return "$site_url/rubyinstaller-$version-x64.7z"
}


# Returns 'exists' | 'missing' | 'unreachable'
function probe_remote_asset($version, $kind) {
    $url = build_download_url $version $kind
    $null = & curl.exe -fsIL --connect-timeout 5 --max-time 10 $url
    if ($LASTEXITCODE -eq 0)  { return 'exists' }
    if ($LASTEXITCODE -eq 22) { return 'missing' }   # curl: HTTP error (404 etc.)
    return 'unreachable'
}


# Resolve a user-given version against the catalog.
# A full version missing from the catalog is accepted if its remote asset exists.
function resolve_remote_version($ver) {
    if ($ver -eq 'head') { return 'head' }

    $ver = [string] $ver
    if ($ver -notmatch '^[0-9]+(\.[0-9]+){0,2}(-[0-9]+)?$') {
        warn "rbenv: invalid version '$ver'"
        exit 1
    }

    $catalog = get_version_catalog
    $match = find_catalog_version $catalog $ver
    if ($match) { return $match }

    # Cache may lag behind a new release; refresh once
    if (-not $RBENV_CATALOG_FETCH_ATTEMPTED) {
        $remote = fetch_remote_catalog
        if ($remote) {
            write_catalog_cache $remote | Out-Null
            $match = find_catalog_version $remote $ver
            if ($match) { return $match }
        }
    }

    if ($ver -match '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$') {
        switch (probe_remote_asset $ver '7z') {
            'exists' {
                warn "rbenv: version $ver is not in the catalog, but its asset exists. Installing anyway"
                return $ver
            }
            'missing' {
                if ($env:RBENV_USE_MIRROR) {
                    warn "rbenv: version $ver not found on the mirror (not synced yet?). Retry later or unset RBENV_USE_MIRROR"
                } else {
                    warn "rbenv: version $ver not found"
                }
            }
            'unreachable' {
                warn "rbenv: version $ver is not in the local catalog, and the remote is unreachable (offline?)"
            }
        }
        exit 1
    }

    warn "rbenv: version $ver not found"
    exit 1
}
