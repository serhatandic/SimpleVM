"""Fixed, allowlisted privileged operations."""

import os
import subprocess

SYSTEMCTL = "/usr/bin/systemctl"
MOUNT = "/usr/bin/mount"
MOUNT_TAG = "share"
MOUNT_POINT = "/mnt/simplevm-share"
MOUNT_FILESYSTEM = "virtiofs"


def validate_mount_request(request):
    return request == {"type": "mountSharedDirectory"}


def shared_mount_status(mountinfo_path="/proc/self/mountinfo"):
    status = {
        "mounted": False,
        "state": "notMounted",
        "mountPoint": MOUNT_POINT,
        "tag": MOUNT_TAG,
        "filesystem": MOUNT_FILESYSTEM,
    }
    try:
        with open(mountinfo_path, "r", encoding="utf-8") as handle:
            for line in handle:
                left, separator, right = line.partition(" - ")
                if not separator:
                    continue
                fields = left.split()
                fs_fields = right.split()
                if len(fields) > 4 and fields[4] == MOUNT_POINT:
                    status["mounted"] = True
                    status["filesystem"] = fs_fields[0] if fs_fields else "unknown"
                    source = fs_fields[1] if len(fs_fields) > 1 else "unknown"
                    status["state"] = (
                        "mounted"
                        if status["filesystem"] == MOUNT_FILESYSTEM
                        and source == MOUNT_TAG
                        else "occupied"
                    )
                    return status
    except OSError:
        status["state"] = "unavailable"
    return status


def mount_shared_directory(run=subprocess.run, makedirs=os.makedirs):
    before = shared_mount_status()
    if before["mounted"]:
        if before["filesystem"] == MOUNT_FILESYSTEM:
            return before
        return dict(before, error="fixed mount point is occupied")
    try:
        makedirs(MOUNT_POINT, mode=0o755, exist_ok=True)
        completed = run(
            [MOUNT, "-t", MOUNT_FILESYSTEM, MOUNT_TAG, MOUNT_POINT],
            shell=False,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return dict(before, state="error", error=str(exc))
    if completed.returncode:
        raced = shared_mount_status()
        if raced["mounted"] and raced["state"] == "mounted":
            return raced
        message = (completed.stderr or "mount failed").strip()[:512]
        return dict(before, state="error", error=message)
    after = shared_mount_status()
    if not after["mounted"] or after["state"] != "mounted":
        return dict(after, state="error", error="mount did not become visible")
    return after


def power(action, run=subprocess.run):
    if action not in ("poweroff", "reboot"):
        raise ValueError("power action is not allowed")
    try:
        completed = run(
            [SYSTEMCTL, action],
            shell=False,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, str(exc)
    if completed.returncode:
        return False, (completed.stderr or "systemctl failed").strip()[:512]
    return True, ""
