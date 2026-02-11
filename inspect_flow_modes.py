"""
Quick script to inspect Flow UI and find available modes
"""

from pychrome import Browser
import time

browser = Browser(url='http://127.0.0.1:9222')
tabs = browser.list_tab()

flow_tab = None
for tab in tabs:
    if hasattr(tab, '__dict__') and '_kwargs' in tab.__dict__:
        tab_url = tab.__dict__['_kwargs'].get('url', '')
        if 'labs.google/fx/tools/flow' in tab_url:
            flow_tab = tab
            break

if not flow_tab:
    print("No Flow tab found")
    exit(1)

flow_tab.start()
time.sleep(2)

# Get all available modes
js_code = """
(() => {
    // Click mode dropdown
    const modeDropdown = document.querySelectorAll('button[role="combobox"]')[0];
    if (!modeDropdown) return {error: 'No dropdown found'};
    
    const currentMode = modeDropdown.textContent;
    modeDropdown.click();
    
    // Wait a bit for dropdown to open
    setTimeout(() => {}, 300);
    
    // Get all options
    const options = Array.from(document.querySelectorAll('div[role="option"]'));
    const modes = options.map(opt => opt.textContent.trim());
    
    // Close dropdown
    document.body.click();
    
    return {
        currentMode: currentMode,
        availableModes: modes,
        totalDropdowns: document.querySelectorAll('button[role="combobox"]').length,
        fileInputs: document.querySelectorAll('input[type="file"]').length
    };
})();
"""

result = flow_tab.call_method('Runtime.evaluate',
                              expression=js_code,
                              returnByValue=True)

data = result.get('result', {}).get('value', {})

print("\n" + "="*60)
print("FLOW UI INSPECTION")
print("="*60)
print(f"\nCurrent Mode: {data.get('currentMode', 'Unknown')}")
print(f"\nAvailable Modes:")
for mode in data.get('availableModes', []):
    print(f"  - {mode}")
print(f"\nTotal Dropdowns: {data.get('totalDropdowns', 0)}")
print(f"File Inputs: {data.get('fileInputs', 0)}")
print("="*60 + "\n")

flow_tab.stop()
