#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Task235: post the issue #11 reply (fatal trace forensics).
import json, urllib.request

TOKEN = open("/home/z/my-project/Amethyst-iOS-MyRemastered/.issue_token").read().strip() if False else None
import subprocess
# token from the repo remote URL (never hardcode -- GH013 push-protection lesson)
url = subprocess.run(["git", "-C", "/home/z/my-project/Amethyst-iOS-MyRemastered", "remote", "get-url", "origin"],
                     capture_output=True, text=True).stdout.strip()
import re
m = re.search(r"https://([^@/]+)@", url)
TOKEN = m.group(1).split(":")[-1] if m else None
assert TOKEN, "no token in origin URL"

body = """Thanks for the detailed report and the attached fatal trace — we went through all 460 entries in it. Here is what the trace actually shows, and what we need from you next.

**What the trace says**

- The crashes are a **deterministic native crash inside the launcher's GL bridge**: every abort trace has the identical frame `gl_init_context + 280940` called from `pojavCreateContext` (via JNI from Java main). The fixed offset means the same instruction faults every time — this is not random memory corruption, and it is not shader-cache corruption.
- The `JVM_handle_bsd_signal` frame is the JVM *catching* that signal and then deliberately aborting — it is a consequence, not the cause.
- The "MSL runtime library linkage" theory in the report does not match the stack: the fault happens inside the launcher's own context-creation code (`gl_init_context`), before any Metal shader translation runs. Purging shader caches or adding `-XX:+IgnoreUnrecognizedVMOptions` will not change this crash.

**What we did on our side**

- The build you tested (from the Sep 22 workflow run) predates a long series of renderer-selection and context-creation fixes. A new build is being published right now (today's commit) which additionally fixes a separate launch crash that affected all game versions (an Objective-C exception in the in-game overlay setup — different signature from yours, but worth retesting anyway).

**What would help us pin yours down**

1. Install the new build from the latest successful workflow run.
2. Before launching, set the renderer explicitly to **MobileGL / MobileGlues** (Settings → renderer). On M-series iPads this is the path that receives the most testing.
3. If it still crashes: the launcher writes `Documents/latestlog.txt` inside the app container — attach that file here. It contains the renderer/runtime decisions made before the crash, which the fatal trace alone does not.
4. Tell us the game version and the renderer you were using when it crashed.

With the new log we can symbolicate the `gl_init_context` offset against the matching dSYM and land a real fix instead of a guess. Thanks again for the thorough report.
"""

req = urllib.request.Request(
    "https://api.github.com/repos/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/issues/11/comments",
    data=json.dumps({"body": body}).encode(),
    headers={"Authorization": f"token {TOKEN}", "Accept": "application/vnd.github+json",
             "User-Agent": "prisma-launcher-maintenance"},
    method="POST")
with urllib.request.urlopen(req) as r:
    out = json.load(r)
print("comment id:", out.get("id"), "url:", out.get("html_url"))
