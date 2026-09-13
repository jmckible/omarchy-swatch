#!/usr/bin/env python3
"""Bounded personal curation state; never reads or changes theme files."""
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import sys

CAP = 131072
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")


def valid_name(value):
    return isinstance(value, str) and NAME.fullmatch(value) and ".." not in value


def valid_background(value):
    return (isinstance(value, str) and len(value.encode()) <= 600
            and value.startswith(("theme:", "extra:"))
            and value.split(":", 1)[1] not in ("", ".", "..")
            and "/" not in value and "\x00" not in value)


def validate(data):
    if not isinstance(data, dict) or set(data) != {"version", "favorites", "hidden"} or data["version"] != 1:
        raise ValueError("Invalid preferences")
    favorites, hidden = data["favorites"], data["hidden"]
    if not isinstance(favorites, list) or len(favorites) > 512 or not all(valid_name(x) for x in favorites):
        raise ValueError("Invalid favorites")
    if not isinstance(hidden, dict) or len(hidden) > 512:
        raise ValueError("Invalid hidden backgrounds")
    for name, entries in hidden.items():
        if (not valid_name(name) or not isinstance(entries, list) or len(entries) > 200
                or not all(valid_background(x) for x in entries)):
            raise ValueError("Invalid hidden background")
    return data


def read(directory):
    try:
        fd = os.open("preferences.json", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
    except FileNotFoundError:
        return {"version": 1, "favorites": [], "hidden": {}}
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > CAP:
            raise ValueError("Refused preferences file")
        raw = source.read(CAP + 1)
    if len(raw) > CAP:
        raise ValueError("Preferences too large")
    return validate(json.loads(raw))


def main():
    signal.alarm(5)
    action = sys.argv[1] if len(sys.argv) > 1 else "read"
    if action not in ("read", "favorite", "hidden"):
        raise ValueError("Unknown action")
    # A read-only script descriptor serializes mutations without a writable lock file.
    with open(__file__, "rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "omarchy/swatch"
        if not path.exists() and action == "read":
            print(json.dumps({"version": 1, "favorites": [], "hidden": {}}))
            return
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            data = read(directory)
            if action != "read":
                name, value = sys.argv[2:4]
                if not valid_name(name) or value not in ("true", "false"):
                    raise ValueError("Invalid preference arguments")
                if action == "favorite":
                    entries, key = data["favorites"], name
                else:
                    key = sys.argv[4]
                    if not valid_background(key):
                        raise ValueError("Invalid background identity")
                    entries = data["hidden"].setdefault(name, [])
                if value == "true" and key not in entries:
                    entries.append(key)
                elif value == "false" and key in entries:
                    entries.remove(key)
                data["hidden"] = {k: v for k, v in data["hidden"].items() if v}
                validate(data)
            raw = json.dumps(data, ensure_ascii=True).encode()
            if len(raw) > CAP:
                raise ValueError("Preferences too large")
            if action != "read":
                temporary = ".preferences-" + secrets.token_hex(16)
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
                try:
                    with os.fdopen(fd, "wb") as target:
                        target.write(raw)
                        target.flush()
                        os.fsync(target.fileno())
                    os.replace(temporary, "preferences.json", src_dir_fd=directory, dst_dir_fd=directory)
                    os.fsync(directory)
                finally:
                    try:
                        os.unlink(temporary, dir_fd=directory)
                    except FileNotFoundError:
                        pass
            print(raw.decode())
        finally:
            os.close(directory)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, IndexError) as error:
        print("swatch preferences: " + str(error), file=sys.stderr)
        sys.exit(1)
