#!/usr/bin/env python3
"""Post a commit comment to GitHub with the contents of a local file.

Usage: python3 scripts/post_comment.py <title> <file_path>
Environment: GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA
"""
import json
import os
import sys
import urllib.request


def main():
    if len(sys.argv) != 3:
        print("Usage: post_comment.py <title> <file_path>", file=sys.stderr)
        sys.exit(1)

    title = sys.argv[1]
    file_path = sys.argv[2]

    token = os.environ["GITHUB_TOKEN"]
    repo = os.environ["GITHUB_REPOSITORY"]
    sha = os.environ["GITHUB_SHA"]

    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    body = f"## {title}\n\n```text\n{content}\n```"
    # GitHub commit comment limit is 65535 characters.
    if len(body) > 65000:
        body = body[:65000] + "\n\n...(truncated)"

    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/commits/{sha}/comments",
        data=json.dumps({"body": body}).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "ci-bot",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print("comment posted", r.status)
    except Exception as e:
        print("comment failed", e)


if __name__ == "__main__":
    main()
