#!/usr/bin/env python3
"""
Conservative cleanup - only remove the old desktop Row layout body,
keeping all methods intact.
"""

import re

def conservative_cleanup(input_file, output_file):
    with open(input_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Find the pattern: after "Use redesigned layout" 
    # Remove from "Container(" for old sidebar to the end of that desktop body section
    # But keep all methods after it
    
    # Pattern: Find the old desktop Container that starts the sidebar
    # This should be AFTER the redesigned layout call
    
    # More precise: Find line with "Use redesigned layout" then find the orphaned Container
    lines = content.split('\n')
    
    start_marker_found = False
    start_remove = -1
    end_remove = -1
    
    for i, line in enumerate(lines):
        # Find where we call redesigned desktop layout
        if "Use redesigned layout" in line and "_buildRedesignedDesktopLayout" in lines[i+1]:
            start_marker_found = True
            # The orphaned code starts a few lines after
            # Look for the orphaned Container
            for j in range(i+1, min(i+20, len(lines))):
                if lines[j].strip().startswith('Container(') and j > i + 1:
                    start_remove = j
                    break
        
        # Find where _buildDrawerContent starts (this is where old code ends)
        if start_marker_found and start_remove > 0 and 'Widget _buildDrawerContent()' in line:
            end_remove = i - 1
            break
    
    if start_remove > 0 and end_remove > start_remove:
        print(f"✅ Found orphaned code from line {start_remove+1} to {end_remove+1}")
        # Remove those lines
        cleaned_lines = lines[:start_remove]
        cleaned_lines.extend(lines[end_remove+1:])
        
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write('\n'.join(cleaned_lines))
        
        print(f"✅ Removed {end_remove - start_remove + 1} orphaned lines")
        print(f"✅ Original: {len(lines)} lines, Cleaned: {len(cleaned_lines)} lines")
    else:
        print(f"❌ Could not find clear markers")
        print(f"   start_remove: {start_remove}, end_remove: {end_remove}")

if __name__ == '__main__':
    input_path = r'c:\Users\Lenovo\Music\veo3_another\lib\main.dart'
    output_path = r'c:\Users\Lenovo\Music\veo3_another\lib\main.dart.cleaned2'
    
    print("🔧 Conservative cleanup of main.dart...")
    conservative_cleanup(input_path, output_path)
