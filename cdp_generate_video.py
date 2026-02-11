import json
import time
import requests
import websocket
import uuid

def generate_video_via_cdp(prompt, debug_port=9222):
    # 1. Get CDP target tab
    try:
        response = requests.get(f"http://localhost:{debug_port}/json")
        tabs = response.json()
    except Exception as e:
        print(f"Error: Could not connect to Chrome on port {debug_port}. Ensure Chrome is running with --remote-debugging-port={debug_port}")
        return

    # Find the Flow tab
    target_tab = next((t for t in tabs if "labs.google/fx/tools/flow" in t.get("url", "")), None)
    if not target_tab:
        print("Error: Could not find any Open Flow tab in Chrome.")
        return

    ws_url = target_tab.get("webSocketDebuggerUrl")
    print(f"Connecting to: {ws_url}")
    
    ws = websocket.create_connection(ws_url)
    
    def send_cmd(method, params=None):
        cmd_id = int(time.time() * 1000)
        ws.send(json.dumps({"id": cmd_id, "method": method, "params": params or {}}))
        while True:
            res = json.loads(ws.recv())
            if res.get("id") == cmd_id:
                return res.get("result")

    def execute_js(code):
        result = send_cmd("Runtime.evaluate", {
            "expression": code,
            "returnByValue": True,
            "awaitPromise": True
        })
        if "exceptionDetails" in result:
            raise Exception(f"JS Error: {result['exceptionDetails']}")
        return result.get("result", {}).get("value")

    print("Fetching tokens...")
    
    # 2. Get Access Token
    get_token_js = 'fetch("https://labs.google/fx/api/auth/session").then(r => r.json()).then(d => d.access_token)'
    access_token = execute_js(get_token_js)
    if not access_token:
        print("Error: Failed to fetch access token.")
        return
    print(f"Access Token: {access_token[:30]}...")

    # 3. Get reCAPTCHA Token
    get_recaptcha_js = 'grecaptcha.enterprise.execute("6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV", {action: "VIDEO_GENERATION"})'
    recaptcha_token = execute_js(get_recaptcha_js)
    if not recaptcha_token:
        print("Error: Failed to fetch reCAPTCHA token.")
        return
    print(f"reCAPTCHA Token: {recaptcha_token[:30]}...")

    # 4. Construct Payload
    project_id = target_tab["url"].split("/")[-1]
    scene_id = str(uuid.uuid4())
    payload = {
        "clientContext": {
            "recaptchaContext": {
                "token": recaptcha_token,
                "applicationType": "RECAPTCHA_APPLICATION_TYPE_WEB"
            },
            "sessionId": f";{int(time.time() * 1000)}",
            "projectId": project_id,
            "tool": "PINHOLE",
            "userPaygateTier": "PAYGATE_TIER_TWO"
        },
        "requests": [
            {
                "aspectRatio": "VIDEO_ASPECT_RATIO_LANDSCAPE",
                "seed": 12345,
                "textInput": {"prompt": prompt},
                "videoModelKey": "veo_3_1_t2v_fast_ultra_relaxed",
                "metadata": {"sceneId": scene_id}
            }
        ]
    }

    # 5. Call API via fetch in browser (to bypass some security checks)
    api_js = f"""
    fetch("https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText", {{
        method: "POST",
        headers: {{
            "Content-Type": "application/json",
            "Authorization": "Bearer {access_token}"
        }},
        body: JSON.stringify({json.dumps(payload)})
    }}).then(r => r.json())
    """
    
    print(f"Triggering generation for prompt: '{prompt}'...")
    api_result = execute_js(api_js)
    print("API Result:")
    print(json.dumps(api_result, indent=2))

    ws.close()

if __name__ == "__main__":
    prompt = "A high-tech laboratory where robots are building other robots"
    generate_video_via_cdp(prompt)
