# RubyInstaller release catalog

$RBENV_CATALOG_API = "https://api.github.com/repos/oneclick/rubyinstaller2/releases"
$RBENV_CATALOG_CACHE_SCHEMA = 2
$RBENV_CATALOG_CACHE_TTL_HOURS = 24
$RBENV_CATALOG_PER_PAGE = 100


function get_catalog_cache_path {
    return "$env:RBENV_ROOT\cache\remote-versions-$(get_current_architecture).json"
}


function sort_catalog_entries($entries) {
    @($entries) | Sort-Object -Descending { version_sort_key $_.version }
}


# Extract the sha256 hex from a GitHub asset 'digest' field, or $null
# (assets uploaded before mid-2025 have no digest)
function asset_digest_sha256($asset) {
    if ([string] $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        return $Matches[1]
    }
    return $null
}


function parse_releases_json($json_text) {
    try {
        $decoded = $json_text | ConvertFrom-Json
        $releases = @($decoded)
    } catch {
        return $null
    }

    $architecture = get_current_architecture
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
        $archive_name = "rubyinstaller-$version-$architecture.7z"
        $devkit_name = "rubyinstaller-devkit-$version-$architecture.exe"

        $archive_asset = $null
        $devkit_asset = $null
        foreach ($asset in @($release.assets)) {
            if ($asset.name -eq $archive_name) { $archive_asset = $asset }
            if ($asset.name -eq $devkit_name)  { $devkit_asset = $asset }
        }

        if ($null -eq $archive_asset) {
            continue
        }

        $devkit_sha256 = $null
        if ($devkit_asset) { $devkit_sha256 = asset_digest_sha256 $devkit_asset }

        $entries += [PSCustomObject] @{
            version = $version
            tag = $tag
            sha256 = asset_digest_sha256 $archive_asset
            devkit_sha256 = $devkit_sha256
            has_devkit = ($null -ne $devkit_asset)
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
            sha256 = $entry.sha256
            devkit_sha256 = $entry.devkit_sha256
            has_devkit = [bool] $entry.has_devkit
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
    $architecture = get_current_architecture
    $versions_path = "$PSScriptRoot\..\share\versions-for-$architecture.json"
    $entries = @()

    foreach ($item in @(Get-Content -LiteralPath $versions_path -Raw | ConvertFrom-Json)) {
        $version = [string] $item.version
        # Also skips the 'head' entry
        if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$') {
            continue
        }

        $entries += [PSCustomObject] @{
            version = $version
            tag = "RubyInstaller-$version"
            sha256 = $item.sha256
            devkit_sha256 = $item.devkit_sha256
            has_devkit = -not [string]::IsNullOrWhiteSpace($item.devkit_sha256)
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
        $_.has_devkit
    } | ForEach-Object {
        $_.version
    })
}


# Segment-aware match (see match_version_prefix in lib/version.ps1).
# The catalog is sorted descending, so the first match is the newest.
function find_catalog_version($catalog, $ver) {
    foreach ($entry in @($catalog.versions)) {
        $full = [string] $entry.version
        if (match_version_prefix $full ([string] $ver)) {
            return $full
        }
    }
    return $null
}


# $kind: '7z' or 'devkit'
# Falls back to the bundled list, which carries hashes for releases
# older than GitHub's asset digests
function catalog_sha256_for_version($version, $kind) {
    $catalogs = @((get_version_catalog))
    if ($catalogs[0].source -ne 'bundled') {
        $catalogs += load_bundled_catalog
    }

    foreach ($catalog in $catalogs) {
        foreach ($entry in @($catalog.versions)) {
            if ($entry.version -ne $version) { continue }

            if ($kind -eq 'devkit') { $sha = [string] $entry.devkit_sha256 }
            else                    { $sha = [string] $entry.sha256 }

            if ($sha -match '^[0-9a-fA-F]{64}$') { return $sha }
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
    $architecture = get_current_architecture

    if ($version -eq 'head') {
        return "https://github.com/oneclick/rubyinstaller2/releases/download/rubyinstaller-head/rubyinstaller-head-$architecture.7z"
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
        return "$site_url/rubyinstaller-devkit-$version-$architecture.exe"
    }
    return "$site_url/rubyinstaller-$version-$architecture.7z"
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
    # A trailing '.' or '-' keeps upstream's explicit-prefix form, e.g. '3.1.'
    if ($ver -notmatch '^[0-9]+(\.[0-9]+){0,2}([.-]|-[0-9]+)?$') {
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

# Force-refresh the catalog cache, ignoring the TTL
function update_version_catalog {
    Write-Host "Updating the RubyInstaller version catalog ..."

    $remote = fetch_remote_catalog
    if ($null -eq $remote) {
        warn "rbenv: Failed to fetch the version catalog from GitHub, keeping the current one"
        return
    }

    write_catalog_cache $remote | Out-Null
    success "rbenv: Version catalog updated ($(@($remote.versions).Count) versions)"
}


# Used by 'rbenv install -l/-a' after printing the list
function warn_if_catalog_stale {
    $catalog = get_version_catalog
    if ($catalog.source -eq 'github-api' -and (catalog_cache_fresh $catalog)) {
        return
    }
    warn "rbenv: this list may be stale (source: $($catalog.source)). Run 'rbenv update versions'"
}
