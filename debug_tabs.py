"""
Debug: Check what pychrome sees
"""
from pychrome import Browser

browser = Browser(url='http://127.0.0.1:9222')
tabs = browser.list_tab()

print(f"\n Found {len(tabs)} tabs:")
for i, tab in enumerate(tabs):
    print(f"\n Tab {i}:")
    print(f"   Type: {type(tab)}")
    print(f"   Dir: {[x for x in dir(tab) if not x.startswith('_')]}")
    
    # Try different ways to access properties
    try:
        print(f"   URL (direct): {tab.url}")
    except:
        print("   URL (direct): FAILED")
    
    try:
        print(f"   URL (str): {str(tab.url)}")
    except:
        print("   URL (str): FAILED")
    
    try:
        print(f"   URL (getattr): {getattr(tab, 'url', 'N/A')}")
    except:
        print("   URL (getattr): FAILED")
    
    try:
        if hasattr(tab, '__dict__'):
            print(f"   Dict: {tab.__dict__}")
    except:
        pass
