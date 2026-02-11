#!/usr/bin/env python3
"""
Remove lines 4266-5949 (the orphaned corrupted section)
"""

def remove_lines(input_file, output_file, start_line, end_line):
    with open(input_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Convert to 0-indexed
    start_idx = start_line - 1
    end_idx = end_line - 1
    
    # Keep lines before and after the range
    cleaned_lines = lines[:start_idx] + lines[end_idx+1:]
    
    with open(output_file, 'w', encoding='utf-8') as f:
        f.writelines(cleaned_lines)
    
    removed = end_idx - start_idx + 1
    print(f"✅ Removed lines {start_line}-{end_line} ({removed} lines)")
    print(f"✅ Original: {len(lines)} lines, Cleaned: {len(cleaned_lines)} lines")

if __name__ == '__main__':
    input_path = r'c:\Users\Lenovo\Music\veo3_another\lib\main.dart'
    output_path = r'c:\Users\Lenovo\Music\veo3_another\lib\main.dart.final'
    
    # Remove the orphaned section (corrupted _buildDrawerContent to real one)
    remove_lines(input_path, output_path, 4266, 5949)
    print(f"\n✅ Cleaned file saved to: {output_path}")
    print("\n📝 Apply with: copy lib\\main.dart.final lib\\main.dart")
