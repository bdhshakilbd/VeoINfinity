# Reel Section Enhancements

## Summary of Changes

### 1. **Global Bulk Auto-Create**
- Added a new "Bulk Auto-Create" control panel above the reels list
- Users can select multiple reels using checkboxes
- "Select All" / "Deselect All" button for quick selection
- Shows count of selected reels
- Start/Stop buttons for bulk processing

### 2. **Concurrent Processing**
- Configurable concurrent processing (1-4 reels at a time, default: 2)
- Processes selected reels in batches to save time
- Progress updates shown during bulk processing
- Final summary shows completed vs failed reels

### 3. **Manual Reel Count Input**
- Replaced 10-reel slider limit with text input field
- Users can now enter any number from 1 to 1000
- More flexible for bulk reel generation

### 4. **Multiple Story Variations per Hint**
- New "Stories/Hint" dropdown (1-5 options)
- When set to > 1, generates N completely different stories from one hint
- Each variation has:
  - Different characters
  - Different settings/locations
  - Different conflicts/challenges
  - Unique plot while maintaining the core theme
- Solves the issue of getting similar stories

### 5. **Multi-line Mode Behavior**
- "Each story per line" mode processes topics one by one (sequential)
- Maintains original behavior for precise control

## UI Changes

### Input Section
```
Reels: [80px text field]    Stories/Hint: [1-5 dropdown]
```

### Bulk Controls Panel (Blue card)
```
┌─────────────────────────────────────────────────────┐
│ 🎨 Bulk Auto-Create              X selected         │
│                                                      │
│ [▶ Start Selected] [⏹ Stop] [☐ Select All]         │
│                                    Concurrent: [2▼]  │
└─────────────────────────────────────────────────────┘
```

### Each Reel Card
```
☑ Reel Name                                    [🗑]
```

## Usage Examples

### Example 1: Generate 20 Different Stories from One Hint
1. Enter topic: "A brave character saves the day"
2. Set Reels: 20
3. Set Stories/Hint: 5
4. Click "Generate Content"
5. Result: 20 reels with 5 unique story variations (4 reels per variation)

### Example 2: Bulk Auto-Create 10 Reels
1. Generate 10 reels
2. Check the boxes for reels you want to auto-create
3. Set Concurrent: 2 (process 2 at a time)
4. Click "Start Selected"
5. System processes 2 reels simultaneously until all are done

### Example 3: Process Multiple Topics One by One
1. Switch to "Each story per line" mode
2. Enter multiple topics (one per line)
3. Click "Generate Content"
4. Each topic is processed sequentially

## Technical Implementation

### State Variables
- `_reelCountController`: TextEditingController for manual input
- `_storiesPerHint`: Number of story variations (1-5)
- `_selectedReelsForBulkCreate`: Set of selected reel indices
- `_isBulkAutoCreating`: Bulk processing status
- `_concurrentReelProcessing`: Concurrent limit (1-4)

### Key Functions
- `_startBulkAutoCreate()`: Processes selected reels in batches
- Updated `_generateReel()`: Handles multiple story variations
- Checkbox integration in reel cards

### Concurrent Processing Logic
```dart
// Process in batches
for (batch in batches) {
  await Future.wait([
    process(reel1),
    process(reel2),
    // ... up to concurrent limit
  ]);
}
```

## Benefits

1. **Time Saving**: Process 2-4 reels simultaneously
2. **Story Diversity**: Get truly different stories from one hint
3. **Scalability**: Generate hundreds of reels without UI limits
4. **Flexibility**: Choose between sequential or concurrent processing
5. **Better UX**: Clear selection, progress tracking, and bulk operations
