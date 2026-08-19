#!/usr/bin/env bash
# ==============================================================================
# manage-vms.sh
# Authoritative gateway and wrapper around QEMU and filesystem operations
# for local virtual machines on macOS.
#
# Forces all VM disk creation, deletion, resizing, cloning, and renaming
# to synchronize atomically with ~/.config/vm-stack/vms.json.
# ==============================================================================

set -euo pipefail

# Expand PATH to find Homebrew / system QEMU binaries
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Terminal styling
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

# Configuration locations
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vm-stack"
REGISTRY_FILE="$CONFIG_DIR/vms.json"
IMAGES_DIR="$CONFIG_DIR/images"

log_info()  { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$1" >&2; }

show_help() {
  cat << EOF
${BOLD}Usage:${RESET} manage-vms.sh <command> [arguments...]

Authoritative QEMU and Filesystem gateway for vm-stack on macOS.
Registry state: ${DIM}$REGISTRY_FILE${RESET}
Default images: ${DIM}$IMAGES_DIR/${RESET}

${BOLD}QEMU & Disk Wrapper Commands:${RESET}
  ${BLUE}create${RESET} <name> [options]         Create a new QEMU disk image and register VM
  ${BLUE}import${RESET} <name> [options]         Inspect an existing disk image and register VM
  ${BLUE}rename${RESET} <old> <new> [options]    Rename VM and optionally rename disk file
  ${BLUE}resize${RESET} <name> <size>            Resize VM disk via qemu-img and update registry
  ${BLUE}clone${RESET} <source> <new> [options]  Clone VM (linked overlay or full copy) and register
  ${BLUE}delete${RESET} <name> [options]         Delete VM registry entry and remove disk file
  ${BLUE}inspect${RESET} <name> [options]        Inspect VM configuration and live qemu-img info
  ${BLUE}sync${RESET} [options]                  Audit & reconcile registry against filesystem

${BOLD}Registry Query & Update Commands:${RESET}
  ${BLUE}list${RESET} [options]                  List all registered VMs (table or JSON)
  ${BLUE}get${RESET} <name> [options]             Get registered VM metadata
  ${BLUE}update${RESET} <name> [options]          Update VM hardware or configuration settings
  ${BLUE}exists${RESET} <name>                   Check if a VM is registered (exit 0=yes, 1=no)
  ${BLUE}path${RESET}                            Print absolute path to the registry file
  ${BLUE}help${RESET}                            Show this help message

${BOLD}Options for 'create':${RESET}
  --size <size>              Virtual disk size (e.g. 20G, 100G) [Required]
  --format <fmt>             Disk format (qcow2, raw) [default: qcow2]
  --disk <path>              Target disk image path [default: images/<name>.<format>]
  --backing-file <path>      Base backing image for copy-on-write
  --arch <arch>              Target architecture (aarch64, x86_64) [default: host arch]
  --memory <size>            Memory allocation (e.g. 4G, 8G) [default: 4G]
  --cpus <n>                 CPU core count [default: 2]
  --os <os_type>             OS label (e.g. ubuntu, debian, alpine, macos) [default: generic]
  --accel <accel>            Acceleration framework (hvf, tcg) [default: hvf]
  --description <text>       Human-readable description
  --extra-args <args>        Extra arguments for QEMU execution

${BOLD}Options for 'import':${RESET}
  --disk <path>              Path to existing disk image [Required]
  --arch, --memory, --cpus, --os, --accel, --description, --extra-args

${BOLD}Options for 'rename':${RESET}
  --rename-disk              Also rename the disk file on filesystem (default: true if in images/)
  --no-rename-disk           Do not rename the disk file on filesystem

${BOLD}Options for 'clone':${RESET}
  --linked                   Create lightweight copy-on-write overlay (default)
  --full                     Create independent full copy via qemu-img convert
  --disk <path>              Target cloned disk path
  --description <text>       Description for cloned VM

${BOLD}Options for 'delete':${RESET}
  --keep-disk                Do not delete the disk image file from disk
  -f, --force                Do not prompt for confirmation

${BOLD}Options for 'inspect' / 'list' / 'get':${RESET}
  -j, --json                 Output machine-readable JSON format
  -q, --quiet                Output VM names only (for 'list')

${BOLD}Options for 'sync':${RESET}
  --prune                    Remove registry entries whose disk files no longer exist

${BOLD}Exit Codes:${RESET}
  0 - Success
  1 - Command or execution error
  2 - VM not found
  3 - VM already exists
EOF
}

# Python core engine executing atomic QEMU and filesystem operations
run_py_gateway() {
  /usr/bin/python3 - "$CONFIG_DIR" "$REGISTRY_FILE" "$IMAGES_DIR" "$@" << 'PYEOF'
import sys
import os
import json
import subprocess
import datetime
import argparse
import shutil

config_dir = sys.argv[1]
registry_path = sys.argv[2]
images_dir = sys.argv[3]
action = sys.argv[4]
args = sys.argv[5:]

def get_host_arch():
    m = os.uname().machine
    if m in ["arm64", "aarch64"]:
        return "aarch64"
    if m in ["x86_64", "amd64"]:
        return "x86_64"
    return m

def get_utc_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def ensure_dirs():
    os.makedirs(config_dir, exist_ok=True)
    os.makedirs(images_dir, exist_ok=True)

def load_registry():
    ensure_dirs()
    if not os.path.exists(registry_path):
        return {"version": 1, "updated_at": get_utc_iso(), "vms": {}}
    try:
        with open(registry_path, "r", encoding="utf-8") as f:
            data = json.load(f)
            if not isinstance(data, dict):
                return {"version": 1, "updated_at": get_utc_iso(), "vms": {}}
            if "vms" not in data or not isinstance(data["vms"], dict):
                data["vms"] = {}
            return data
    except Exception:
        return {"version": 1, "updated_at": get_utc_iso(), "vms": {}}

def save_registry(data):
    ensure_dirs()
    data["updated_at"] = get_utc_iso()
    temp_file = f"{registry_path}.tmp.{os.getpid()}"
    with open(temp_file, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(temp_file, registry_path)

def run_qemu_img_info(disk_path):
    if not os.path.exists(disk_path):
        return None
    try:
        res = subprocess.run(
            ["qemu-img", "info", "--output=json", disk_path],
            capture_output=True,
            text=True,
            check=True
        )
        return json.loads(res.stdout)
    except Exception as e:
        return None

def format_size(bytes_val):
    if bytes_val is None:
        return "unknown"
    try:
        b = float(bytes_val)
        for unit in ["B", "K", "M", "G", "T"]:
            if b < 1024.0 or unit == "T":
                if unit in ["B", "K"]:
                    return f"{int(b)}{unit}"
                return f"{b:.1f}{unit}"
            b /= 1024.0
    except Exception:
        return str(bytes_val)

# ──────────────────────────────────────────────────────────────────────────
# Action Implementations
# ──────────────────────────────────────────────────────────────────────────

if action == "path":
    print(os.path.abspath(registry_path))
    sys.exit(0)

elif action == "exists":
    if len(args) < 1:
        sys.exit(1)
    name = args[0]
    data = load_registry()
    if name in data["vms"]:
        sys.exit(0)
    else:
        sys.exit(1)

elif action == "create":
    parser = argparse.ArgumentParser(prog="manage-vms create")
    parser.add_argument("name")
    parser.add_argument("--size", required=True, help="Virtual disk size, e.g. 20G")
    parser.add_argument("--format", default="qcow2", choices=["qcow2", "raw"])
    parser.add_argument("--disk", default="")
    parser.add_argument("--backing-file", default="")
    parser.add_argument("--arch", default=get_host_arch())
    parser.add_argument("--memory", default="4G")
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--os", default="generic")
    parser.add_argument("--accel", default="hvf")
    parser.add_argument("--description", default="")
    parser.add_argument("--extra-args", default="")

    parsed = parser.parse_args(args)
    data = load_registry()
    name = parsed.name.strip()

    if not name:
        print("[ERROR] VM name cannot be empty.", file=sys.stderr)
        sys.exit(1)

    if name in data["vms"]:
        print(f"[ERROR] VM '{name}' already exists in registry.", file=sys.stderr)
        sys.exit(3)

    disk_path = parsed.disk
    if not disk_path:
        disk_path = os.path.join(images_dir, f"{name}.{parsed.format}")
    disk_path = os.path.abspath(disk_path)

    os.makedirs(os.path.dirname(disk_path), exist_ok=True)

    # Build qemu-img create command
    cmd = ["qemu-img", "create", "-f", parsed.format]
    if parsed.backing_file:
        backing_abs = os.path.abspath(parsed.backing_file)
        if not os.path.exists(backing_abs):
            print(f"[ERROR] Backing file not found: {parsed.backing_file}", file=sys.stderr)
            sys.exit(1)
        cmd.extend(["-b", backing_abs, "-F", "qcow2"])
    cmd.extend([disk_path, parsed.size])

    try:
        print(f"[INFO] Running: {' '.join(cmd)}")
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] qemu-img create failed with code {e.returncode}.", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("[ERROR] 'qemu-img' command not found in PATH.", file=sys.stderr)
        sys.exit(1)

    # Inspect created disk
    info = run_qemu_img_info(disk_path)
    virtual_size = parsed.size
    fmt = parsed.format
    if info:
        virtual_size = format_size(info.get("virtual-size"))
        fmt = info.get("format", parsed.format)

    vm_entry = {
        "name": name,
        "arch": parsed.arch,
        "os": parsed.os,
        "disk": disk_path,
        "format": fmt,
        "virtual_size": virtual_size,
        "backing_file": os.path.abspath(parsed.backing_file) if parsed.backing_file else None,
        "memory": parsed.memory,
        "cpus": parsed.cpus,
        "accel": parsed.accel,
        "description": parsed.description,
        "status": "stopped",
        "extra_args": parsed.extra_args,
        "created_at": get_utc_iso(),
        "updated_at": get_utc_iso()
    }

    data["vms"][name] = vm_entry
    save_registry(data)
    print(f"[INFO] Successfully created disk and registered VM '{name}' ({virtual_size} {fmt}).")
    sys.exit(0)

elif action == "import":
    parser = argparse.ArgumentParser(prog="manage-vms import")
    parser.add_argument("name")
    parser.add_argument("--disk", required=True)
    parser.add_argument("--arch", default=get_host_arch())
    parser.add_argument("--memory", default="4G")
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--os", default="generic")
    parser.add_argument("--accel", default="hvf")
    parser.add_argument("--description", default="")
    parser.add_argument("--extra-args", default="")

    parsed = parser.parse_args(args)
    data = load_registry()
    name = parsed.name.strip()

    if name in data["vms"]:
        print(f"[ERROR] VM '{name}' already exists in registry.", file=sys.stderr)
        sys.exit(3)

    disk_path = os.path.abspath(parsed.disk)
    if not os.path.exists(disk_path):
        print(f"[ERROR] Disk image file not found: {parsed.disk}", file=sys.stderr)
        sys.exit(1)

    info = run_qemu_img_info(disk_path)
    fmt = "qcow2"
    vsize = "unknown"
    backing = None
    if info:
        fmt = info.get("format", "qcow2")
        vsize = format_size(info.get("virtual-size"))
        backing = info.get("backing-filename")

    vm_entry = {
        "name": name,
        "arch": parsed.arch,
        "os": parsed.os,
        "disk": disk_path,
        "format": fmt,
        "virtual_size": vsize,
        "backing_file": os.path.abspath(backing) if backing else None,
        "memory": parsed.memory,
        "cpus": parsed.cpus,
        "accel": parsed.accel,
        "description": parsed.description,
        "status": "stopped",
        "extra_args": parsed.extra_args,
        "created_at": get_utc_iso(),
        "updated_at": get_utc_iso()
    }

    data["vms"][name] = vm_entry
    save_registry(data)
    print(f"[INFO] Imported VM '{name}' from {disk_path} ({vsize} {fmt}).")
    sys.exit(0)

elif action == "rename":
    parser = argparse.ArgumentParser(prog="manage-vms rename")
    parser.add_argument("old_name")
    parser.add_argument("new_name")
    parser.add_argument("--rename-disk", dest="rename_disk", action="store_true", default=None)
    parser.add_argument("--no-rename-disk", dest="rename_disk", action="store_false")

    parsed = parser.parse_args(args)
    data = load_registry()
    old_name = parsed.old_name.strip()
    new_name = parsed.new_name.strip()

    if old_name not in data["vms"]:
        print(f"[ERROR] VM '{old_name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    if new_name in data["vms"]:
        print(f"[ERROR] VM '{new_name}' already exists in registry.", file=sys.stderr)
        sys.exit(3)

    vm = data["vms"][old_name]
    old_disk = vm.get("disk", "")
    new_disk = old_disk

    should_rename_disk = parsed.rename_disk
    if should_rename_disk is None:
        # Default to renaming disk if inside images_dir or named after VM
        if old_disk and (images_dir in old_disk or old_name in os.path.basename(old_disk)):
            should_rename_disk = True
        else:
            should_rename_disk = False

    if should_rename_disk and old_disk and os.path.exists(old_disk):
        dirname = os.path.dirname(old_disk)
        ext = os.path.splitext(old_disk)[1] or ".qcow2"
        new_disk = os.path.join(dirname, f"{new_name}{ext}")
        try:
            print(f"[INFO] Moving disk: {old_disk} -> {new_disk}")
            shutil.move(old_disk, new_disk)
        except Exception as e:
            print(f"[ERROR] Failed to move disk file: {e}", file=sys.stderr)
            sys.exit(1)

    vm["name"] = new_name
    vm["disk"] = new_disk
    vm["updated_at"] = get_utc_iso()

    del data["vms"][old_name]
    data["vms"][new_name] = vm
    save_registry(data)
    print(f"[INFO] Renamed VM '{old_name}' to '{new_name}'.")
    sys.exit(0)

elif action == "resize":
    if len(args) < 2:
        print("[ERROR] Usage: manage-vms.sh resize <name> <size> (e.g. +10G, 50G)", file=sys.stderr)
        sys.exit(1)

    name = args[0].strip()
    new_size = args[1].strip()
    data = load_registry()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]
    disk_path = vm.get("disk", "")
    if not disk_path or not os.path.exists(disk_path):
        print(f"[ERROR] Disk image for VM '{name}' does not exist: {disk_path}", file=sys.stderr)
        sys.exit(1)

    cmd = ["qemu-img", "resize", disk_path, new_size]
    try:
        print(f"[INFO] Running: {' '.join(cmd)}")
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] qemu-img resize failed with code {e.returncode}.", file=sys.stderr)
        sys.exit(1)

    info = run_qemu_img_info(disk_path)
    if info:
        vm["virtual_size"] = format_size(info.get("virtual-size"))
    vm["updated_at"] = get_utc_iso()
    save_registry(data)
    print(f"[INFO] Resized VM '{name}' disk to {vm.get('virtual_size')}.")
    sys.exit(0)

elif action == "clone":
    parser = argparse.ArgumentParser(prog="manage-vms clone")
    parser.add_argument("source_name")
    parser.add_argument("new_name")
    parser.add_argument("--linked", action="store_true", default=True)
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--disk", default="")
    parser.add_argument("--description", default="")

    parsed = parser.parse_args(args)
    data = load_registry()
    src_name = parsed.source_name.strip()
    new_name = parsed.new_name.strip()

    if src_name not in data["vms"]:
        print(f"[ERROR] Source VM '{src_name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    if new_name in data["vms"]:
        print(f"[ERROR] Target VM '{new_name}' already exists in registry.", file=sys.stderr)
        sys.exit(3)

    src_vm = data["vms"][src_name]
    src_disk = src_vm.get("disk", "")

    if not src_disk or not os.path.exists(src_disk):
        print(f"[ERROR] Source disk image not found: {src_disk}", file=sys.stderr)
        sys.exit(1)

    target_disk = parsed.disk
    if not target_disk:
        target_disk = os.path.join(images_dir, f"{new_name}.qcow2")
    target_disk = os.path.abspath(target_disk)
    os.makedirs(os.path.dirname(target_disk), exist_ok=True)

    if parsed.full:
        # Full copy via convert
        cmd = ["qemu-img", "convert", "-O", "qcow2", src_disk, target_disk]
        backing_ref = None
        clone_type = "Full clone"
    else:
        # Linked copy-on-write overlay
        cmd = ["qemu-img", "create", "-f", "qcow2", "-b", src_disk, "-F", "qcow2", target_disk]
        backing_ref = src_disk
        clone_type = "Linked overlay clone"

    try:
        print(f"[INFO] Running: {' '.join(cmd)}")
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] qemu-img failed during clone: code {e.returncode}.", file=sys.stderr)
        sys.exit(1)

    info = run_qemu_img_info(target_disk)
    vsize = format_size(info.get("virtual-size")) if info else src_vm.get("virtual_size")

    new_vm = {
        "name": new_name,
        "arch": src_vm.get("arch", get_host_arch()),
        "os": src_vm.get("os", "generic"),
        "disk": target_disk,
        "format": "qcow2",
        "virtual_size": vsize,
        "backing_file": backing_ref,
        "memory": src_vm.get("memory", "4G"),
        "cpus": src_vm.get("cpus", 2),
        "accel": src_vm.get("accel", "hvf"),
        "description": parsed.description or f"Clone of {src_name}",
        "status": "stopped",
        "extra_args": src_vm.get("extra_args", ""),
        "created_at": get_utc_iso(),
        "updated_at": get_utc_iso()
    }

    data["vms"][new_name] = new_vm
    save_registry(data)
    print(f"[INFO] {clone_type} '{new_name}' created from '{src_name}'.")
    sys.exit(0)

elif action == "delete":
    parser = argparse.ArgumentParser(prog="manage-vms delete")
    parser.add_argument("name")
    parser.add_argument("--keep-disk", action="store_true")
    parser.add_argument("-f", "--force", action="store_true")

    parsed = parser.parse_args(args)
    data = load_registry()
    name = parsed.name.strip()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]
    disk_path = vm.get("disk", "")

    if not parsed.keep_disk and disk_path and os.path.exists(disk_path):
        try:
            print(f"[INFO] Removing disk file: {disk_path}")
            os.remove(disk_path)
        except Exception as e:
            print(f"[WARN] Could not remove disk file: {e}", file=sys.stderr)

    del data["vms"][name]
    save_registry(data)
    print(f"[INFO] Deleted VM '{name}' from registry.")
    sys.exit(0)

elif action == "inspect":
    parser = argparse.ArgumentParser(prog="manage-vms inspect")
    parser.add_argument("name")
    parser.add_argument("-j", "--json", action="store_true")
    parsed = parser.parse_args(args)

    data = load_registry()
    name = parsed.name.strip()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]
    disk_path = vm.get("disk", "")
    disk_exists = os.path.exists(disk_path) if disk_path else False
    disk_info = run_qemu_img_info(disk_path) if disk_exists else None

    actual_file_size = format_size(os.path.getsize(disk_path)) if disk_exists else "missing"

    combined = {
        "vm": vm,
        "disk_status": {
            "path": disk_path,
            "exists": disk_exists,
            "actual_size_on_disk": actual_file_size,
            "qemu_info": disk_info
        }
    }

    if parsed.json:
        print(json.dumps(combined, indent=2))
        sys.exit(0)

    print(f"VM Name:           {vm.get('name')}")
    print(f"Architecture:      {vm.get('arch')}")
    print(f"OS:                {vm.get('os')}")
    print(f"CPUs:              {vm.get('cpus')}")
    print(f"Memory:            {vm.get('memory')}")
    print(f"Acceleration:      {vm.get('accel')}")
    print(f"Status:            {vm.get('status')}")
    print(f"Disk Path:         {disk_path or '<none>'}")
    print(f"Disk File Exists:  {'Yes' if disk_exists else 'NO (Missing)'}")
    print(f"Actual Disk Size:  {actual_file_size}")
    print(f"Virtual Disk Size: {vm.get('virtual_size', 'unknown')}")
    print(f"Format:            {vm.get('format', 'unknown')}")
    print(f"Backing File:      {vm.get('backing_file') or '<none>'}")
    print(f"Description:       {vm.get('description') or '<none>'}")
    print(f"Extra Args:        {vm.get('extra_args') or '<none>'}")
    print(f"Created:           {vm.get('created_at')}")
    print(f"Updated:           {vm.get('updated_at')}")
    sys.exit(0)

elif action == "sync":
    parser = argparse.ArgumentParser(prog="manage-vms sync")
    parser.add_argument("--prune", action="store_true")
    parsed = parser.parse_args(args)

    data = load_registry()
    vms = data["vms"]
    changes = 0
    to_delete = []

    print(f"[INFO] Auditing {len(vms)} registered VM(s)...")

    for name, vm in vms.items():
        disk = vm.get("disk", "")
        if not disk or not os.path.exists(disk):
            print(f"  [WARN] VM '{name}': Disk missing ({disk})")
            if parsed.prune:
                to_delete.append(name)
        else:
            info = run_qemu_img_info(disk)
            if info:
                vsize = format_size(info.get("virtual-size"))
                fmt = info.get("format", vm.get("format"))
                backing = info.get("backing-filename")
                if vm.get("virtual_size") != vsize or vm.get("format") != fmt:
                    vm["virtual_size"] = vsize
                    vm["format"] = fmt
                    vm["updated_at"] = get_utc_iso()
                    changes += 1

    if to_delete:
        for name in to_delete:
            del data["vms"][name]
            changes += 1
            print(f"  [INFO] Pruned VM '{name}' from registry.")

    if changes > 0:
        save_registry(data)
        print(f"[INFO] Reconciled registry: {changes} update(s) saved.")
    else:
        print("[INFO] Registry is in sync with filesystem.")
    sys.exit(0)

elif action == "list":
    parser = argparse.ArgumentParser(prog="manage-vms list")
    parser.add_argument("-j", "--json", action="store_true")
    parser.add_argument("-q", "--quiet", action="store_true")
    parsed = parser.parse_args(args)

    data = load_registry()
    vms = data["vms"]

    if parsed.json:
        print(json.dumps(list(vms.values()), indent=2))
        sys.exit(0)

    if parsed.quiet:
        for name in sorted(vms.keys()):
            print(name)
        sys.exit(0)

    if not vms:
        print("No virtual machines registered. Run 'manage-vms.sh create <name> --size <size>' to create one.")
        sys.exit(0)

    headers = ["NAME", "ARCH", "CPUS", "MEM", "VSIZE", "FORMAT", "STATUS", "DISK"]
    rows = []
    for name in sorted(vms.keys()):
        v = vms[name]
        disk_str = v.get("disk", "")
        if len(disk_str) > 30:
            disk_str = "..." + disk_str[-27:]
        rows.append([
            v.get("name", name),
            v.get("arch", "unknown"),
            str(v.get("cpus", 2)),
            v.get("memory", "4G"),
            v.get("virtual_size", "unknown"),
            v.get("format", "qcow2"),
            v.get("status", "stopped"),
            disk_str or "<none>"
        ])

    col_widths = [len(h) for h in headers]
    for row in rows:
        for i, val in enumerate(row):
            col_widths[i] = max(col_widths[i], len(val))

    header_fmt = "  ".join(f"{{:<{w}}}" for w in col_widths)
    print(header_fmt.format(*headers))
    print("  ".join("-" * w for w in col_widths))
    for row in rows:
        print(header_fmt.format(*row))

    sys.exit(0)

elif action == "get":
    parser = argparse.ArgumentParser(prog="manage-vms get")
    parser.add_argument("name")
    parser.add_argument("-j", "--json", action="store_true")
    parsed = parser.parse_args(args)

    data = load_registry()
    name = parsed.name.strip()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]

    if parsed.json:
        print(json.dumps(vm, indent=2))
        sys.exit(0)

    print(f"Name:             {vm.get('name')}")
    print(f"Architecture:     {vm.get('arch')}")
    print(f"OS:               {vm.get('os')}")
    print(f"CPUs:             {vm.get('cpus')}")
    print(f"Memory:           {vm.get('memory')}")
    print(f"Acceleration:     {vm.get('accel')}")
    print(f"Format:           {vm.get('format')}")
    print(f"Virtual Size:     {vm.get('virtual_size')}")
    print(f"Backing File:     {vm.get('backing_file') or '<none>'}")
    print(f"Status:           {vm.get('status')}")
    print(f"Disk Image:       {vm.get('disk') or '<none>'}")
    print(f"Description:      {vm.get('description') or '<none>'}")
    print(f"Extra Args:       {vm.get('extra_args') or '<none>'}")
    print(f"Created At:       {vm.get('created_at')}")
    print(f"Updated At:       {vm.get('updated_at')}")
    sys.exit(0)

elif action == "update":
    parser = argparse.ArgumentParser(prog="manage-vms update")
    parser.add_argument("name")
    parser.add_argument("--disk", default=None)
    parser.add_argument("--arch", default=None)
    parser.add_argument("--memory", default=None)
    parser.add_argument("--cpus", type=int, default=None)
    parser.add_argument("--os", default=None)
    parser.add_argument("--accel", default=None)
    parser.add_argument("--status", default=None)
    parser.add_argument("--description", default=None)
    parser.add_argument("--extra-args", default=None)

    parsed = parser.parse_args(args)
    data = load_registry()
    name = parsed.name.strip()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]
    updated_fields = []

    if parsed.disk is not None:
        vm["disk"] = os.path.abspath(parsed.disk) if parsed.disk else ""
        info = run_qemu_img_info(vm["disk"])
        if info:
            vm["format"] = info.get("format", vm.get("format"))
            vm["virtual_size"] = format_size(info.get("virtual-size"))
        updated_fields.append("disk")
    if parsed.arch is not None:
        vm["arch"] = parsed.arch
        updated_fields.append("arch")
    if parsed.memory is not None:
        vm["memory"] = parsed.memory
        updated_fields.append("memory")
    if parsed.cpus is not None:
        vm["cpus"] = parsed.cpus
        updated_fields.append("cpus")
    if parsed.os is not None:
        vm["os"] = parsed.os
        updated_fields.append("os")
    if parsed.accel is not None:
        vm["accel"] = parsed.accel
        updated_fields.append("accel")
    if parsed.status is not None:
        vm["status"] = parsed.status
        updated_fields.append("status")
    if parsed.description is not None:
        vm["description"] = parsed.description
        updated_fields.append("description")
    if parsed.extra_args is not None:
        vm["extra_args"] = parsed.extra_args
        updated_fields.append("extra_args")

    vm["updated_at"] = get_utc_iso()
    save_registry(data)
    print(f"[INFO] Updated VM '{name}' ({', '.join(updated_fields) if updated_fields else 'no changes'}).")
    sys.exit(0)

else:
    print(f"[ERROR] Unknown action: {action}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Command dispatch
if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

COMMAND="$1"
shift

case "$COMMAND" in
  create|add)
    run_py_gateway "create" "$@"
    ;;
  import|register)
    run_py_gateway "import" "$@"
    ;;
  rename|mv)
    run_py_gateway "rename" "$@"
    ;;
  resize)
    run_py_gateway "resize" "$@"
    ;;
  clone|cp)
    run_py_gateway "clone" "$@"
    ;;
  delete|rm|destroy|remove|unregister)
    run_py_gateway "delete" "$@"
    ;;
  inspect|info)
    run_py_gateway "inspect" "$@"
    ;;
  sync)
    run_py_gateway "sync" "$@"
    ;;
  list|ls)
    run_py_gateway "list" "$@"
    ;;
  get|show)
    run_py_gateway "get" "$@"
    ;;
  update|set)
    run_py_gateway "update" "$@"
    ;;
  exists)
    run_py_gateway "exists" "$@"
    ;;
  path)
    run_py_gateway "path"
    ;;
  -h|--help|help)
    show_help
    exit 0
    ;;
  *)
    log_error "Unknown command: $COMMAND"
    show_help
    exit 1
    ;;
esac
