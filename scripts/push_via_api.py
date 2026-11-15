#!/usr/bin/env python3
"""通过 GitHub API 推送工作树到远端分支。

适用场景：80/443 被中间设备干扰导致 git push 的 TLS 握手失败。
做法是逐文件比对本地与远端 tree 的 blob sha，只上传差异，最后建一个
commit 指向新的 tree。内容与本地完全一致，但远端 commit 的 SHA 会和
本地不同（历史被压平为一个提交）。

用法：python3 push_api.py <owner/repo> <branch> [commit-message-file]
环境：GITHUB_TOKEN
"""
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO = sys.argv[1]
BRANCH = sys.argv[2]
MSG_FILE = sys.argv[3] if len(sys.argv) > 3 else None
TOKEN = os.environ["GITHUB_TOKEN"]

API = "https://api.github.com"


def call(method, path, payload=None):
    url = f"{API}/repos/{REPO}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"{method} {path} -> {exc.code}: {exc.read().decode()[:400]}")


def git(*args, binary=False):
    out = subprocess.check_output(["git", *args])
    return out if binary else out.decode().strip()


remote_ref = call("GET", f"/git/ref/heads/{BRANCH}")
remote_sha = remote_ref["object"]["sha"]
remote_commit = call("GET", f"/git/commits/{remote_sha}")
base_tree = remote_commit["tree"]["sha"]
print(f"远端 HEAD {remote_sha[:7]}")

remote_tree = call("GET", f"/git/trees/{base_tree}?recursive=1")
remote_files = {
    item["path"]: item["sha"]
    for item in remote_tree.get("tree", [])
    if item["type"] == "blob"
}

local_files = [p for p in git("-c", "core.quotepath=false", "ls-files").split("\n") if p]
print(f"本地 {len(local_files)} 个文件 / 远端 {len(remote_files)} 个文件")

entries = []
uploaded = 0
for path in local_files:
    local_sha = git("hash-object", path)
    if remote_files.get(path) == local_sha:
        continue
    with open(path, "rb") as handle:
        content = handle.read()
    blob = call(
        "POST",
        "/git/blobs",
        {"content": base64.b64encode(content).decode(), "encoding": "base64"},
    )
    entries.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    uploaded += 1
    print(f"  ↑ {path} ({len(content)} B)")

deleted = [p for p in remote_files if p not in set(local_files)]
for path in deleted:
    entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
    print(f"  ✕ {path}")

if not entries:
    print("内容已一致，无需提交")
    raise SystemExit(0)

if MSG_FILE and os.path.exists(MSG_FILE):
    message = open(MSG_FILE, encoding="utf-8").read().strip()
else:
    message = git("log", "-1", "--pretty=%B")

tree = call("POST", "/git/trees", {"base_tree": base_tree, "tree": entries})
commit = call(
    "POST",
    "/git/commits",
    {"message": message, "tree": tree["sha"], "parents": [remote_sha]},
)
print(f"新提交 {commit['sha'][:7]}")

call("PATCH", f"/git/refs/heads/{BRANCH}", {"sha": commit["sha"], "force": False})
print(f"已更新 {BRANCH} -> {commit['sha'][:7]}（上传 {uploaded} / 删除 {len(deleted)}）")
