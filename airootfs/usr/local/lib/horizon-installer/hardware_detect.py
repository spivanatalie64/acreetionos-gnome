#!/usr/bin/env python3
"""Hardware detection and driver auto-selection for AcreetionOS Calamares installer."""
from pathlib import Path
import re
import subprocess
import yaml


def normalize_pci_id(raw_value):
    value = (raw_value or "").strip().lower()
    if not value:
        return value
    if value.startswith("0x"):
        value = value[2:]
    return f"0x{value}"


def read_sys_file(path):
    try:
        return Path(path).read_text().strip()
    except (OSError, IOError):
        return ""


def detect_pci_devices(sysfs_root="/sys/bus/pci/devices"):
    devices = []
    pci_dir = Path(sysfs_root)
    if not pci_dir.is_dir():
        return devices

    for dev_path in pci_dir.iterdir():
        vendor = normalize_pci_id(read_sys_file(dev_path / "vendor"))
        device_id = normalize_pci_id(read_sys_file(dev_path / "device"))
        pci_class = normalize_pci_id(read_sys_file(dev_path / "class"))
        if not vendor or not pci_class:
            continue
        devices.append({
            "slot": dev_path.name,
            "vendor": vendor,
            "device": device_id,
            "class": pci_class,
            "path": dev_path,
        })
    return devices


def detect_cpu(cpuinfo_path="/proc/cpuinfo"):
    content = read_sys_file(cpuinfo_path)
    if "AuthenticAMD" in content:
        return "amd", "AMD CPU", ["amd-ucode"], ["Amd-ucode (microcode)"]
    elif "GenuineIntel" in content:
        return "intel", "Intel CPU", ["intel-ucode"], ["Intel-ucode (microcode)"]
    return "unknown", "Generic x86_64 CPU", [], []


def detect_gpu(pci_devices):
    # Class 0x0300 = VGA controller, 0x0302 = 3D controller, 0x0380 = Display controller
    display_devices = []
    for dev in pci_devices:
        pci_class = normalize_pci_id(dev.get("class"))
        if (pci_class.startswith("0x0300") or pci_class.startswith("0x0302") or
                pci_class.startswith("0x0380")):
            display_devices.append({**dev, "class": pci_class})

    results = []
    for dev in display_devices:
        vendor = normalize_pci_id(dev["vendor"])
        if vendor == "0x10de":  # NVIDIA
            arch, desc = classify_nvidia(dev)
            if arch == "turing_plus":
                results.append({
                    "vendor": "nvidia",
                    "arch": arch,
                    "desc": desc,
                    "packages": ["nvidia-open-dkms", "nvidia-utils", "nvidia-settings", "lib32-nvidia-utils"],
                    "groups": [
                        "Nvidia for latest Linux Kernel",
                        "Nvidia-Lts for Linux-Lts Kernel",
                        "Nvidia for Linux-Zen Kernel",
                        "Nvidia-Lts for Linux-Zen lts Kernel",
                    ],
                })
            elif arch == "pascal_volta":
                results.append({
                    "vendor": "nvidia",
                    "arch": arch,
                    "desc": desc,
                    "packages": ["nvidia-dkms", "nvidia-utils", "nvidia-settings", "lib32-nvidia-utils"],
                    "groups": [
                        "Nvidia for latest Linux Kernel",
                        "Nvidia-Lts for Linux-Lts Kernel",
                        "Nvidia for Linux-Zen Kernel",
                        "Nvidia-Lts for Linux-Zen lts Kernel",
                    ],
                })
            else:
                results.append({
                    "vendor": "nvidia",
                    "arch": "legacy",
                    "desc": f"Legacy NVIDIA GPU ({desc}) - using open-source nouveau",
                    "packages": ["lib32-mesa", "mesa"],
                    "groups": [],
                })

        elif vendor == "0x1002":  # AMD
            results.append({
                "vendor": "amd",
                "arch": "amdgpu",
                "desc": "AMD Radeon Graphics",
                "packages": ["lib32-mesa", "vulkan-radeon", "lib32-vulkan-radeon", "vulkan-icd-loader", "lib32-vulkan-icd-loader"],
                "groups": ["AMD Graphics Drivers"],
            })

        elif vendor == "0x8086":  # Intel
            results.append({
                "vendor": "intel",
                "arch": "intel_arc_xe_hd",
                "desc": "Intel HD/Iris/Arc Graphics",
                "packages": ["intel-media-driver", "intel-media-sdk", "lib32-mesa", "vulkan-intel", "vulkan-icd-loader", "lib32-vulkan-icd-loader"],
                "groups": ["Intel Graphics Drivers"],
            })

        elif vendor == "0x80ee":  # VirtualBox
            results.append({
                "vendor": "virtualbox",
                "arch": "vboxvideo",
                "desc": "Oracle VirtualBox Graphics Adapter",
                "packages": ["virtualbox-guest-utils"],
                "groups": [],
            })

        elif vendor == "0x15ad":  # VMware
            results.append({
                "vendor": "vmware",
                "arch": "vmwgfx",
                "desc": "VMware SVGA II Adapter",
                "packages": ["xf86-video-vmware"],
                "groups": [],
            })

        elif vendor == "0x1af4":  # QEMU Virtio GPU
            results.append({
                "vendor": "qemu",
                "arch": "virtio-gpu",
                "desc": "QEMU Virtio GPU",
                "packages": ["mesa", "lib32-mesa"],
                "groups": [],
            })

    return results


def classify_nvidia(dev):
    desc = ""
    try:
        lspci_out = subprocess.check_output(
            ["lspci", "-nn", "-s", dev["slot"]],
            stderr=subprocess.DEVNULL,
            text=True
        ).strip()
        desc = lspci_out.split(":", 2)[-1].strip() if ":" in lspci_out else lspci_out
    except Exception:
        desc = f"NVIDIA device {dev.get('device', 'unknown')}"

    desc_upper = desc.upper()
    # Check for known modern Turing+ identifiers (RTX 20xx+, GTX 16xx+, Quadro RTX, Ada Lovelace, Blackwell, Hopper)
    turing_plus_patterns = [
        r"\bRTX\b", r"\bGTX\s*16", r"\bTU[0-9]{3}", r"\bGA[0-9]{3}",
        r"\bAD[0-9]{3}", r"\bGB[0-9]{3}", r"\bGH[0-9]{3}", r"TITAN\s*RTX"
    ]
    for pat in turing_plus_patterns:
        if re.search(pat, desc_upper):
            return "turing_plus", desc

    # Check for Pascal / Volta (GTX 10xx, TITAN Xp, TITAN V, GP1xx, GV1xx)
    pascal_patterns = [
        r"\bGTX\s*10", r"\bGP[0-9]{3}", r"\bGV[0-9]{3}", r"TITAN\s*XP?", r"TITAN\s*V"
    ]
    for pat in pascal_patterns:
        if re.search(pat, desc_upper):
            return "pascal_volta", desc

    # Check for older legacy models
    legacy_patterns = [
        r"\bGTX\s*[4-9][0-9]{2}", r"\bGT\s*[2-9][0-9]{2}", r"\bGM[0-9]{3}",
        r"\bGK[0-9]{3}", r"\bGF[0-9]{3}", r"GEFORCE\s*[6-9][0-9]{3}"
    ]
    for pat in legacy_patterns:
        if re.search(pat, desc_upper):
            return "legacy", desc

    # Fallback to turing_plus for unclassified modern cards, or legacy if unknown
    return "turing_plus", desc


def detect_network_drivers(pci_devices):
    results = []
    for dev in pci_devices:
        if dev["vendor"] == "0x14e4":  # Broadcom
            results.append({
                "name": "Broadcom Wireless",
                "packages": ["broadcom-wl-dkms"],
                "groups": [],
            })
    return results


def detect_all_hardware(sysfs_root="/sys/bus/pci/devices", cpuinfo_path="/proc/cpuinfo"):
    pci_devs = detect_pci_devices(sysfs_root=sysfs_root)
    cpu_vendor, cpu_desc, cpu_pkgs, cpu_groups = detect_cpu(cpuinfo_path=cpuinfo_path)
    gpus = detect_gpu(pci_devs)
    network = detect_network_drivers(pci_devs)

    all_groups = set(cpu_groups)
    all_packages = set(cpu_pkgs)

    for g in gpus:
        all_groups.update(g["groups"])
        all_packages.update(g["packages"])

    for n in network:
        all_groups.update(n["groups"])
        all_packages.update(n["packages"])

    return {
        "cpu": {"vendor": cpu_vendor, "desc": cpu_desc, "packages": cpu_pkgs, "groups": cpu_groups},
        "gpus": gpus,
        "network": network,
        "recommended_groups": sorted(all_groups),
        "recommended_packages": sorted(all_packages),
    }


def apply_hardware_to_drivers_catalogue(catalogue_path, hardware_info):
    path = Path(catalogue_path)
    if not path.is_file():
        return False

    groups = yaml.safe_load(path.read_text()) or []
    recommended_groups = set(hardware_info.get("recommended_groups", []))

    # Determine kernel preference (default linux-lts)
    kernel_groups = {
        "Latest Linux Kernel",
        "Latest Linux-Lts Kernel",
        "Latest Linux-Zen Kernel (Gamers recommended)",
    }

    gpu_vendors = {g["vendor"] for g in hardware_info.get("gpus", [])}
    has_nvidia = "nvidia" in gpu_vendors
    nvidia_arch = next((g["arch"] for g in hardware_info.get("gpus", []) if g["vendor"] == "nvidia"), None)

    for group in groups:
        name = group.get("name", "")
        # Don't deselect the default kernel
        if name in kernel_groups:
            continue

        if name in recommended_groups:
            group["hidden"] = False
            # Tailor Nvidia group to LTS kernel by default if multiple matched
            if "Nvidia" in name:
                if "Lts" in name:
                    group["selected"] = True
                    group["description"] = f"{group.get('description', '')} [Auto-detected: NVIDIA {nvidia_arch}]"
                else:
                    group["selected"] = False
            else:
                group["selected"] = True
                hw_tag = hardware_info["cpu"]["desc"] if "code" in name else "Auto-detected hardware"
                group["description"] = f"{group.get('description', '')} [{hw_tag}]"
        else:
            # If it's a driver group that does not match this hardware, deselect it
            if any(k in name for k in ("Nvidia", "AMD Graphics", "Intel Graphics", "ucode")):
                group["selected"] = False

    path.write_text(yaml.safe_dump(groups, sort_keys=False))
    return True


def format_driver_summary(hardware_info):
    lines = []
    lines.append(f"* CPU Microcode: {hardware_info['cpu']['desc']}")
    if hardware_info["cpu"]["packages"]:
        lines.append(f"    Driver: {', '.join(hardware_info['cpu']['packages'])}")
    else:
        lines.append("    Driver: Standard kernel support")

    if hardware_info["gpus"]:
        for i, gpu in enumerate(hardware_info["gpus"], 1):
            lines.append(f"* Graphics Device {i}: {gpu['desc']}")
            lines.append(f"    Driver: {', '.join(gpu['packages'])}")
    else:
        lines.append("* Graphics: Generic / Integrated Display (Mesa Gallium)")

    if hardware_info["network"]:
        for net in hardware_info["network"]:
            lines.append(f"* Network Adapter: {net['name']}")
            lines.append(f"    Driver: {', '.join(net['packages'])}")

    return "\n".join(lines)
