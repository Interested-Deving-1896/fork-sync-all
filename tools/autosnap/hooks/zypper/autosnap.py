"""
Zypper plugin for autosnap.

Zypper calls plugins via the zypper-plugin protocol over stdin/stdout.
Install to /usr/lib/zypp/plugins/commit/autosnap

The plugin protocol sends JSON messages; we respond with ACK to each.
See: https://doc.opensuse.org/projects/libzypp/HEAD/zypp-plugins.html
"""

import json
import os
import subprocess
import sys


def send(message: dict) -> None:
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def recv() -> dict:
    line = sys.stdin.readline()
    if not line:
        return {}
    return json.loads(line.strip())


def run_autosnap(*args, packages: str = "") -> None:
    env = os.environ.copy()
    if packages:
        env["AUTOSNAP_PACKAGES"] = packages
    try:
        subprocess.run(
            ["/usr/bin/autosnap", *args],
            check=False,
            timeout=120,
            input=packages.encode() if packages else None,
            env=env,
        )
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"autosnap: {exc}\n")


def main() -> None:
    while True:
        msg = recv()
        if not msg:
            break

        command = msg.get("command", "")

        if command == "PLUGINBEGIN":
            send({"command": "ACK"})

        elif command == "COMMITBEGIN":
            # Extract package list from the commit message if available
            pkgs = " ".join(msg.get("packages", []))
            run_autosnap("pre", "zypper", packages=pkgs)
            send({"command": "ACK"})

        elif command == "COMMITEND":
            pkgs = " ".join(msg.get("packages", []))
            run_autosnap("post", "zypper", packages=pkgs)
            send({"command": "ACK"})

        elif command == "PLUGINEND":
            send({"command": "ACK"})
            break

        else:
            # Unknown command — ACK to avoid blocking zypper
            send({"command": "ACK"})


if __name__ == "__main__":
    main()
