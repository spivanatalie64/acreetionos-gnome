#!/usr/bin/env python3
"""Restores preserved user data from Windows, macOS, or Linux into the target system user's home folder."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


BACKUP_DIR = Path("/var/acreetion-data-backup")
DATA_MOUNT_BACKUP = Path("/run/media/data-partition/acreetion-saved-files")
LOG_FILE = Path("/var/log/calamares-restore-data.log")


def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{msg}\n")
    except Exception:
        pass
    print(msg)


def find_backup_source():
    if BACKUP_DIR.is_dir():
        items = [i for i in BACKUP_DIR.iterdir() if i.name != "backup_manifest.json"]
        if items:
            return BACKUP_DIR
    if DATA_MOUNT_BACKUP.is_dir():
        items = [i for i in DATA_MOUNT_BACKUP.iterdir() if i.name != "backup_manifest.json"]
        if items:
            return DATA_MOUNT_BACKUP
    return None


def find_target_username(target_root):
    home_dir = Path(target_root) / "home"
    if home_dir.is_dir():
        for user_folder in sorted(home_dir.iterdir()):
            if user_folder.is_dir() and user_folder.name not in ("lost+found", "liveuser", "root"):
                return user_folder.name

    passwd_file = Path(target_root) / "etc" / "passwd"
    if passwd_file.is_file():
        try:
            for line in passwd_file.read_text().splitlines():
                parts = line.split(":")
                if len(parts) >= 3:
                    uid = int(parts[2])
                    if 1000 <= uid < 60000:
                        return parts[0]
        except Exception:
            pass
    return None


def restore_user_files(target_root="/"):
    log(f"Starting data restoration to target root: {target_root}")
    source_dir = find_backup_source()
    if not source_dir:
        log("No preserved backup files found. Skipping restore.")
        return 0

    username = find_target_username(target_root)
    if not username:
        log("No regular user found in target system. Preserving in /root/Preserved_Files")
        dest_folder = Path(target_root) / "root" / "Preserved_Files"
    else:
        dest_folder = Path(target_root) / "home" / username / "Preserved_Files"

    dest_folder.mkdir(parents=True, exist_ok=True)
    log(f"Restoring files from {source_dir} to {dest_folder}")

    copied_count = 0
    for item in source_dir.iterdir():
        if item.name == "backup_manifest.json":
            continue
        dest_item = dest_folder / item.name
        try:
            if item.is_dir():
                shutil.copytree(item, dest_item, dirs_exist_ok=True)
            else:
                shutil.copy2(item, dest_item)
            copied_count += 1
            log(f"  Restored: {item.name}")
        except Exception as e:
            log(f"  Error restoring {item.name}: {e}")

    # Set ownership if username was found
    if username:
        try:
            # Look up uid/gid inside chroot passwd
            passwd_file = Path(target_root) / "etc" / "passwd"
            uid, gid = 1000, 1000
            if passwd_file.is_file():
                for line in passwd_file.read_text().splitlines():
                    parts = line.split(":")
                    if parts[0] == username:
                        uid, gid = int(parts[2]), int(parts[3])
                        break
            for root, dirs, files in os.walk(dest_folder):
                os.chown(root, uid, gid)
                for d in dirs:
                    os.chown(os.path.join(root, d), uid, gid)
                for f in files:
                    os.chown(os.path.join(root, f), uid, gid)
            log(f"Successfully chowned {dest_folder} to {username} ({uid}:{gid})")
        except Exception as e:
            log(f"Warning: chown failed: {e}")

    log(f"Finished data restoration. Total items restored: {copied_count}")
    return 0


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "/"
    sys.exit(restore_user_files(target))

