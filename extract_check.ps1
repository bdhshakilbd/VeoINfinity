# Extract reel-related methods from story_audio_screen.dart to a new file
$source = Get-Content "h:\gravityapps\veo3_another\lib\screens\story_audio_screen.dart" -Raw

# Read the original file lines
$lines = Get-Content "h:\gravityapps\veo3_another\lib\screens\story_audio_screen.dart"

# Extract _buildReelTab method (lines 1504-3028, 0-indexed: 1503-3027)
$reelTabContent = $lines[1503..3027] -join "
"

# Extract reel methods (lines 3036-3830)
$reelMethods1 = $lines[3035..3829] -join "
"

# Extract more reel methods (lines 4739-5279)
$reelMethods2 = $lines[4738..5278] -join "
"

# Output stats
Write-Output "ReelTab lines: $($lines[1503..3027].Count)"
Write-Output "ReelMethods1 lines: $($lines[3035..3829].Count)"
Write-Output "ReelMethods2 lines: $($lines[4738..5278].Count)"
