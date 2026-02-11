"""
Quick fix for the f-string syntax error in bulk_video_generator.py
"""

# Read the file
with open('bulk_video_generator.py', 'r', encoding='utf-8') as f:
    content = f.read()

# Find and replace the problematic line
old_line = "                    textarea.value = `{prompt.replace('`', '\\\\`')}`;"
new_lines = """                    // Set new prompt (escaped)
                    const promptText = `""" + "{escaped_prompt}" + """`;
                    textarea.value = promptText;"""

# Also need to add the escaping before the js_type
old_section = """            print(f"[UI-AUTO] Typing prompt ({len(prompt)} chars)...")
            
            js_type = f'''"""

new_section = """            print(f"[UI-AUTO] Typing prompt ({len(prompt)} chars)...")
            
            # Escape special characters for JavaScript
            escaped_prompt = prompt.replace('\\\\', '\\\\\\\\').replace('`', '\\\\`').replace('$', '\\\\$')
            
            js_type = f'''"""

content = content.replace(old_section, new_section)
content = content.replace(old_line, new_lines)

# Write back
with open('bulk_video_generator.py', 'w', encoding='utf-8') as f:
    f.write(content)

print("✓ Fixed the f-string syntax error!")
print("  - Added prompt escaping before js_type")
print("  - Replaced problematic template literal line")
