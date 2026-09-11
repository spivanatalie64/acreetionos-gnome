#!/usr/bin/env python3
"""Data migration assistant: scan existing Windows, macOS, or Linux installs,
prompt user, open file manager to preserve files to a data partition/staging area,
and facilitate reapplication at installation finish.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


BACKUP_DIR = Path("/var/acreetion-data-backup")
MOUNT_BASE = Path("/run/media/source-os")


def get_block_devices():
    try:
        out = subprocess.check_output(
            ["lsblk", "-J", "-o", "NAME,PATH,FSTYPE,LABEL,SIZE,MOUNTPOINT,TYPE"],
            text=True, stderr=subprocess.DEVNULL
        )
        data = json.loads(out)
        return flatten_devices(data.get("blockdevices", []))
    except Exception:
        return []


def flatten_devices(dev_list):
    flat = []
    for d in dev_list:
        flat.append(d)
        if "children" in d:
            flat.extend(flatten_devices(d["children"]))
    return flat


def identify_os_on_partition(mount_path, fstype):
    p = Path(mount_path)
    os_info = None

    # Check for Windows
    for win_dir in ("Windows", "windows", "WINDOWS"):
        if (p / win_dir).is_dir():
            users_exist = any((p / u).is_dir() for u in ("Users", "users", "USERS"))
            return "Windows", f"Windows Installation {'(with User profiles)' if users_exist else ''}"

    # Check for macOS
    if (p / "System" / "Library" / "CoreServices").is_dir() or (p / "Applications").is_dir() and (p / "Users").is_dir():
        return "macOS", "macOS Installation"

    # Check for Linux
    if (p / "etc" / "os-release").is_file() or (p / "usr" / "lib" / "os-release").is_file():
        distro = "Linux"
        try:
            rel_file = p / "etc" / "os-release" if (p / "etc" / "os-release").is_file() else p / "usr" / "lib" / "os-release"
            for line in rel_file.read_text(errors="ignore").splitlines():
                if line.startswith("PRETTY_NAME="):
                    distro = line.split("=", 1)[1].strip('"\'')
                    break
        except Exception:
            pass
        return "Linux", distro

    # Standalone user home partition
    if (p / "home").is_dir() or any((p / d).is_dir() for d in ("Desktop", "Documents", "Downloads")):
        return "Data/User Partition", "User Data Partition"

    return None


def scan_for_existing_installations():
    devices = get_block_devices()
    found = []
    MOUNT_BASE.mkdir(parents=True, exist_ok=True)

    supported_fs = {
        "ntfs", "vfat", "ext4", "ext3", "ext2", "btrfs", "xfs", "f2fs", "hfsplus", "apfs", "exfat"
    }

    for dev in devices:
        fstype = (dev.get("fstype") or "").lower()
        dev_path = dev.get("path") or ""
        dev_type = dev.get("type") or ""

        if dev_type not in ("part", "disk") or fstype not in supported_fs:
            continue

        # Skip loop, live media, or swap
        if "loop" in dev_path or "airoot" in dev_path:
            continue

        temp_mount = MOUNT_BASE / f"inspect_{dev.get('name')}"
        temp_mount.mkdir(parents=True, exist_ok=True)
        mounted_by_us = False

        try:
            if not dev.get("mountpoint"):
                res = subprocess.run(
                    ["mount", "-o", "ro", dev_path, str(temp_mount)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
                if res.returncode == 0:
                    mounted_by_us = True
                    inspect_path = temp_mount
                else:
                    continue
            else:
                inspect_path = Path(dev["mountpoint"])

            detected = identify_os_on_partition(inspect_path, fstype)
            if detected:
                os_type, os_desc = detected
                found.append({
                    "device": dev_path,
                    "name": dev.get("name"),
                    "fstype": fstype,
                    "label": dev.get("label") or "Unlabeled",
                    "size": dev.get("size", ""),
                    "os_type": os_type,
                    "os_desc": os_desc,
                })
        finally:
            if mounted_by_us:
                subprocess.run(["umount", str(temp_mount)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    temp_mount.rmdir()
                except OSError:
                    pass

    return found


def prompt_user_for_backup(found_installations):
    try:
        import gi
        gi.require_version('Gtk', '3.0')
        from gi.repository import Gtk, Gdk
    except Exception:
        return False

    summary_text = "\n".join(
        f"• {item['os_type']}: {item['os_desc']} on {item['device']} ({item['size']})"
        for item in found_installations
    )

    dialog = Gtk.MessageDialog(
        flags=Gtk.DialogFlags.MODAL,
        type=Gtk.MessageType.QUESTION,
        buttons=Gtk.ButtonsType.NONE,
        message_format="Existing Operating System(s) Detected!"
    )
    dialog.set_title("AcreetionOS Data Preservation")
    dialog.set_default_size(520, 260)
    dialog.set_position(Gtk.WindowPosition.CENTER)

    dialog.format_secondary_text(
        f"The installer detected the following installations on your drives:\n\n"
        f"{summary_text}\n\n"
        f"Would you like to open the file manager to select and save any files, "
        f"documents, or photos before continuing with partitioning?\n\n"
        f"Saved files will be safely stored and automatically restored to your new user account."
    )

    btn_continue = dialog.add_button("Continue Without Saving", Gtk.ResponseType.NO)
    btn_save = dialog.add_button("Open File Manager to Save Files", Gtk.ResponseType.YES)
    btn_save.get_style_context().add_class("suggested-action")

    response = dialog.run()
    dialog.destroy()
    return response == Gtk.ResponseType.YES


def find_data_partition():
    devices = get_block_devices()
    for dev in devices:
        label = (dev.get("label") or "").upper()
        if label in ("DATA", "STORAGE", "BACKUP", "FILES") and dev.get("path"):
            return dev["path"]
    return None


def run_migration_file_manager(found_installations):
    MOUNT_BASE.mkdir(parents=True, exist_ok=True)
    mounted_sources = []

    for item in found_installations:
        dev_path = item["device"]
        clean_name = item["name"]
        mount_dir = MOUNT_BASE / f"{item['os_type']}_{clean_name}"
        mount_dir.mkdir(parents=True, exist_ok=True)
        res = subprocess.run(
            ["mount", "-o", "ro", dev_path, str(mount_dir)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        if res.returncode == 0:
            mounted_sources.append(mount_dir)

    # Determine destination directory
    data_part = find_data_partition()
    dest_dir = BACKUP_DIR
    data_mount = Path("/run/media/data-partition")

    if data_part:
        data_mount.mkdir(parents=True, exist_ok=True)
        if subprocess.run(["mount", data_part, str(data_mount)], stdout=subprocess.DEVNULL).returncode == 0:
            dest_dir = data_mount / "acreetion-saved-files"

    dest_dir.mkdir(parents=True, exist_ok=True)

    # Launch file manager (Nautilus or xdg-open)
    fm = "nautilus" if shutil.which("nautilus") else "xdg-open"
    sources_to_open = [str(s) for s in mounted_sources] or [str(MOUNT_BASE)]
    fm_process = subprocess.Popen([fm, str(dest_dir)] + sources_to_open)

    # Show helper dialog waiting for user to finish copying
    try:
        import gi
        gi.require_version('Gtk', '3.0')
        from gi.repository import Gtk

        info_dialog = Gtk.Dialog(
            title="Preserving Your Files",
            flags=Gtk.DialogFlags.MODAL,
            buttons=("Done - Proceed to Installer", Gtk.ResponseType.OK)
        )
        info_dialog.set_default_size(480, 200)
        info_dialog.set_position(Gtk.WindowPosition.CENTER)
        content_box = info_dialog.get_content_area()
        content_box.set_spacing(12)
        content_box.set_border_width(20)

        label = Gtk.Label()
        label.set_markup(
            f"<b>File Manager is now open.</b>\n\n"
            f"1. Browse your detected OS files under <b>{MOUNT_BASE}</b>.\n"
            f"2. Copy any folders or documents into <b>{dest_dir}</b>.\n\n"
            f"When you have finished copying your files, click <b>Done</b> below to continue."
        )
        label.set_line_wrap(True)
        content_box.pack_start(label, True, True, 0)
        info_dialog.show_all()
        info_dialog.run()
        info_dialog.destroy()
    except Exception:
        # Fallback to waiting for file manager process if GUI dialog fails
        fm_process.wait()

    # Record metadata of saved files for the restore step
    saved_items = list(dest_dir.iterdir()) if dest_dir.is_dir() else []
    metadata_file = BACKUP_DIR / "backup_manifest.json"
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    metadata = {
        "saved_count": len(saved_items),
        "source_installations": [f["os_type"] for f in found_installations],
        "dest_dir": str(dest_dir),
    }
    metadata_file.write_text(json.dumps(metadata, indent=2))

    # Unmount source partitions safely
    for m in mounted_sources:
        subprocess.run(["umount", str(m)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def check_and_run_migration():
    """Main entrypoint for migration check."""
    installations = scan_for_existing_installations()
    if not installations:
        return True  # No OS found, continue immediately

    wants_backup = prompt_user_for_backup(installations)
    if wants_backup:
        run_migration_file_manager(installations)

    return True


if __name__ == "__main__":
    check_and_run_migration()

