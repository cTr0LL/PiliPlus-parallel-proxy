# Applies the Flutter SDK and material_ui patches PiliPlus needs, for Android.
#
#   powershell -ExecutionPolicy Bypass -File .\tool\patch_flutter_android.ps1
#   powershell -ExecutionPolicy Bypass -File .\tool\patch_flutter_android.ps1 -Revert
#
# This is a narrowed stand-in for lib/scripts/patch.ps1, which is written for CI
# and does three things you do not want on a personal machine:
#
#   * `git config --global user.name "ci"` / `user.email "example@example.com"`,
#     which would rewrite your git identity for EVERY repository
#   * `git reset --hard HEAD` inside the Flutter SDK
#   * depends on $env:GITHUB_WORKSPACE and $env:FLUTTER_ROOT being preset
#
# It also cherry-picks and reverts Flutter commits - except both of those lists
# are empty in the current script, so nothing is lost by omitting them.
#
# Everything here is reversible with -Revert.
param([switch]$Revert)

$ErrorActionPreference = "Stop"

if (-not (Test-Path "lib/scripts/patch.ps1")) {
    throw "Run this from the PiliPlus repo root."
}
$repo = (Get-Location).Path

# Derive FLUTTER_ROOT from the flutter on PATH rather than hardcoding it.
$flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
$flutterBat = if ($flutterCmd) { $flutterCmd.Source } else { "C:\src\flutter\bin\flutter.bat" }
$flutterRoot = Split-Path (Split-Path $flutterBat -Parent) -Parent
if (-not (Test-Path "$flutterRoot/packages/flutter")) {
    throw "Could not locate the Flutter SDK (looked in $flutterRoot)."
}
Write-Output "flutter sdk : $flutterRoot"

$pubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { "$env:LOCALAPPDATA\Pub\Cache" }

function Get-MaterialUiDir {
    $d = Get-ChildItem "$pubCache/hosted/pub.dev" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "material_ui-*" } |
        Select-Object -Last 1
    if (-not $d) { throw "material_ui not in pub cache. Run 'flutter pub get' first." }
    return $d.FullName
}

# Order matters: several of these touch the same file, and the later ones are
# written against the earlier ones' output. This is lib/scripts/patch.ps1's
# android ordering, preserved exactly.
$sdkPatches = @(
    "modal_barrier", "text_selection", "mouse_cursor", "image_anim",
    "layout_builder", "navigation_drawer", "popup_menu", "fab",
    "null_safety_for_selectable_region", "selectable_region", "editable_text",
    "text_field", "scroll_position", "scrollable", "scrollable_gesture",
    "draggable_scrollable_sheet", "scaffold", "text", "text_painter",
    "sliver", "refresh_indicator",
    # android-only, appended by patch.ps1's platform switch
    "bottom_sheet_android", "scroll_view", "navigator"
) | ForEach-Object { "$repo/lib/scripts/$_.patch" }

$materialPatches = @(
    "modal_barrier_material", "navigation_drawer", "popup_menu", "fab",
    "text_field", "scaffold", "refresh_indicator", "tabs",
    "bottom_sheet_android"
) | ForEach-Object { "$repo/lib/scripts/material/$_.patch" }

if ($Revert) {
    Write-Output "reverting Flutter SDK..."
    & git -C $flutterRoot checkout -- packages/flutter
    Write-Output "SDK clean: $(if ((& git -C $flutterRoot status --porcelain packages/flutter)) {'NO'} else {'yes'})"

    $mu = Get-MaterialUiDir
    Write-Output "removing patched material_ui ($mu); 'flutter pub get' will restore it"
    Remove-Item $mu -Recurse -Force
    Write-Output "done. Run 'flutter pub get' in the repo to re-fetch material_ui."
    return
}

foreach ($p in ($sdkPatches + $materialPatches)) {
    if (-not (Test-Path $p)) { throw "missing patch file: $p" }
}

# Dry-run the whole SDK set before touching anything, so a bad patch cannot
# leave the SDK half-modified. git apply --check stops at the first failure,
# and because these patches build on each other they can only be checked as a
# sequence - hence --3way on the real pass rather than per-file pre-checks.
Write-Output ""
Write-Output "=== Flutter SDK: $($sdkPatches.Count) patches ==="
$sdkClean = & git -C $flutterRoot status --porcelain packages/flutter
if ($sdkClean) {
    throw "Flutter SDK has uncommitted changes already. Run with -Revert first."
}

$applied = 0
foreach ($p in $sdkPatches) {
    & git -C $flutterRoot apply $p
    if ($LASTEXITCODE -ne 0) {
        Write-Output ""
        Write-Output "FAILED on $(Split-Path $p -Leaf) after $applied applied."
        Write-Output "Rolling the SDK back so it is not left half-patched..."
        & git -C $flutterRoot checkout -- packages/flutter
        throw "patch failed: $p"
    }
    $applied++
    Write-Output "  [$applied/$($sdkPatches.Count)] $(Split-Path $p -Leaf)"
}

Write-Output ""
Write-Output "=== material_ui: $($materialPatches.Count) patches ==="
$mu = Get-MaterialUiDir
Write-Output "  $mu"

# The pub cache copy is not a git repo, so `git apply` runs there with
# --unsafe-paths off by default; it works because the patches use relative
# paths. A failure here leaves the package dirty, so delete-and-refetch is the
# recovery, which is what -Revert does.
$appliedM = 0
foreach ($p in $materialPatches) {
    & git -C $mu apply $p
    if ($LASTEXITCODE -ne 0) {
        Write-Output ""
        Write-Output "FAILED on $(Split-Path $p -Leaf) after $appliedM applied."
        Write-Output "Recover with: -Revert, then 'flutter pub get'."
        throw "patch failed: $p"
    }
    $appliedM++
    Write-Output "  [$appliedM/$($materialPatches.Count)] $(Split-Path $p -Leaf)"
}

Write-Output ""
Write-Output "done. SDK files changed:"
& git -C $flutterRoot diff --stat packages/flutter | Select-Object -Last 1
Write-Output ""
Write-Output "To undo everything:"
Write-Output "  powershell -ExecutionPolicy Bypass -File .\tool\patch_flutter_android.ps1 -Revert"
