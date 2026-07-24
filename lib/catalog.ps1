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
