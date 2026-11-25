# Self-check for lib/catalog.ps1 version sorting and resolution.
# No network, no RBENV_ROOT needed.
#
#   powershell -NoProfile -File test\catalog-check.ps1
#   pwsh       -NoProfile -File test\catalog-check.ps1

$ErrorActionPreference = 'Stop'
$script:failed = $false

. $PSScriptRoot\..\lib\core.ps1
. $PSScriptRoot\..\lib\catalog.ps1

function assert_eq($actual, $expected, $label) {
    if ("$actual" -ne "$expected") {
        Write-Host "FAIL $label : got '$actual', want '$expected'" -f red
        $script:failed = $true
    } else {
        Write-Host "ok   $label"
    }
}

$entries = @('3.1.2-1', '3.10.0-1', '4.0.9-1', '4.0.10-1', '3.4.4-2', '3.4.4-1') |
    ForEach-Object {
        [PSCustomObject] @{
            version = $_
            tag = "RubyInstaller-$_"
            x64_7z = $true
            devkit_x64_exe = $true
        }
    }

# --- numeric sort ---
$sorted = @(sort_catalog_entries $entries)
assert_eq $sorted[0].version '4.0.10-1' 'sort: 4.0.10-1 above 4.0.9-1'
assert_eq $sorted[2].version '3.10.0-1' 'sort: 3.10.x above 3.4.x'
assert_eq $sorted[3].version '3.4.4-2'  'sort: revision 2 above revision 1'

$catalog = [PSCustomObject] @{
    schema_version = 1
    fetched_at = [DateTimeOffset]::UtcNow.ToString('o')
    source = 'github-api'
    versions = $sorted
}

# --- segment-aware matching ---
assert_eq (find_catalog_version $catalog '3.1')     '3.1.2-1'  'match: 3.1 does not hit 3.10.x'
assert_eq (find_catalog_version $catalog '3.10')    '3.10.0-1' 'match: 3.10 hits 3.10.x'
assert_eq (find_catalog_version $catalog '4')       '4.0.10-1' 'match: 4 picks newest 4.x'
assert_eq (find_catalog_version $catalog '3.4.4')   '3.4.4-2'  'match: 3.4.4 picks newest revision'
assert_eq (find_catalog_version $catalog '4.0.9-1') '4.0.9-1'  'match: exact full version'
assert_eq (find_catalog_version $catalog '4.0.1')   ''         'match: 4.0.1 does not hit 4.0.10-1'
assert_eq (find_catalog_version $catalog '9.9')     ''         'match: unknown series'

# --- resolution (catalog and network stubbed out) ---
function get_version_catalog { $catalog }
function fetch_remote_catalog { $null }
$script:RBENV_CATALOG_FETCH_ATTEMPTED = $true

assert_eq (resolve_remote_version 'head') 'head'     'resolve: head is literal'
assert_eq (resolve_remote_version '4.0') '4.0.10-1'  'resolve: prefix picks newest'

function probe_remote_asset { 'exists' }
assert_eq (resolve_remote_version '4.0.11-1' 6>$null 2>$null) '4.0.11-1' 'resolve: full version outside catalog, asset exists'

if ($script:failed) { exit 1 }
Write-Host 'all ok' -f green
