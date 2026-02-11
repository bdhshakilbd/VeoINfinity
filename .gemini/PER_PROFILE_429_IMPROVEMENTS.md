# Per-Profile 429 Rate Limit Improvements

## Problem Statement
Previously, when ANY profile hit a 429 rate limit error:
- ALL profiles were paused for 30 seconds globally
- Scenes were retried with the SAME profile that failed
- Other healthy profiles sat idle waiting unnecessarily

## Solution Implemented

### 1. Per-Profile Cooldown Tracking
- **New State Variable**: `Map<String, DateTime> _profile429Times`
- Tracks cooldown end time for each profile independently
- Only the affected profile waits 30s, others continue working

### 2. Smart Profile Selection
- **Updated `_getNextProfile()`**:
  - Checks if profile is in cooldown before returning it
  - Automatically skips profiles in 429 cooldown
  - Clears expired cooldowns automatically
  - Returns `null` if all profiles are in cooldown

### 3. Improved Error Handling
- **Updated `_handle429Error()`**:
  - Takes `profileName` parameter to identify which profile failed
  - Sets 30s cooldown for ONLY that specific profile
  - Requeues scene at front for immediate retry with DIFFERENT profile
  - Logs which profile is in cooldown

### 4. Better Wait Logic
- **Updated `_runConcurrentGeneration()`**:
  - Removed global 30s pause for all profiles
  - Now waits 3s if all profiles are in cooldown
  - Shows which profiles are in cooldown and time remaining
  - Continues immediately when any profile becomes available

## Expected Behavior

### Scenario: Profile 1 gets 429
**Old Behavior**:
1. Profile 1 hits 429 on Scene 5
2. ALL profiles wait 30s
3. Scene 5 retries with Profile 1 again
4. Profiles 2, 3, 4 sit idle

**New Behavior**:
1. Profile 1 hits 429 on Scene 5
2. ONLY Profile 1 goes into 30s cooldown
3. Scene 5 immediately retries with Profile 2
4. Profiles 2, 3, 4 continue generating
5. Profile 1 automatically rejoins after 30s

### Scenario: All profiles get 429
1. Profiles 1, 2, 3, 4 all hit 429 at different times
2. Each has independent cooldown timer
3. Generator waits 3s and checks again
4. As soon as ANY profile's cooldown expires, it's used
5. Profiles become available in rolling fashion

## Benefits

✅ **Better Profile Utilization**: Healthy profiles keep working
✅ **Faster Generation**: No global pauses
✅ **Smarter Retry Logic**: Failed scenes try different profiles
✅ **Independent Cooldowns**: Each profile tracked separately
✅ **Better Logging**: See which profile is in cooldown and for how long

## Code Changes

### Files Modified
- `lib/services/video_generation_service.dart`

### Key Changes
1. Added `_profile429Times` map (line ~57)
2. Updated `_getNextProfile()` to check cooldowns (line ~1242)
3. Updated `_handle429Error()` to accept profileName (line ~910)
4. Updated error handling call site to pass profileName (line ~636)
5. Removed global 429 wait logic (line ~332)
6. Added cooldown status logging (line ~338)

## Testing Recommendations

1. **Single Profile 429**: Verify only that profile waits
2. **Multiple Profile 429**: Verify independent cooldowns
3. **All Profiles 429**: Verify orderly recovery
4. **Normal/Boost Modes**: Test both generation modes
5. **Batch/Single**: Test both batch and single generation

## Backward Compatibility

- Global `_last429Time` retained for compatibility
- Still set during 429 errors
- New code uses per-profile tracking
- Old code paths won't break
