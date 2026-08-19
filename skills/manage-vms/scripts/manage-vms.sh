#!/usr/bin/env bash
# ==============================================================================
# manage-vms.sh
# macOS-focused local VM registry management for vm-stack.
# Stores VM definitions in ~/.config/vm-stack/vms.json.
# ==============================================================================

set -euo pipefail

# Terminal styling
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

# Locate configuration directory and registry file
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vm-stack"
REGISTRY_FILE="$CONFIG_DIR/vms.json"

# Logging helpers
log_info()  { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$1" >&2; }

ensure_config_dir() {
  if [[ ! -d "$CONFIG_DIR" ]]; then
    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  fi
}

show_help() {
  cat << EOF
${BOLD}Usage:${RESET} manage-vms.sh <command> [arguments...]

Manage local virtual machine registry for vm-stack on macOS.
State is stored in: ${DIM}$REGISTRY_FILE${RESET}

${BOLD}Commands:${RESET}
  ${BLUE}add${RESET} <name> [options]         Register a new VM
  ${BLUE}list${RESET} [options]               List all registered VMs
  ${BLUE}get${RESET} <name> [options]          Get details of a specific VM
  ${BLUE}update${RESET} <name> [options]       Update metadata or resource allocations of a VM
  ${BLUE}delete${RESET} <name> [options]       Remove a VM from the registry
  ${BLUE}exists${RESET} <name>                Check if a VM exists (exit 0=yes, 1=no)
  ${BLUE}path${RESET}                         Print the absolute path to the registry file
  ${BLUE}help${RESET}                         Show this help message

${BOLD}Options for 'add':${RESET}
  --disk <path>              Path to the VM disk image (e.g. .qcow2 or .img)
  --arch <arch>              Target architecture (aarch64, x86_64) [default: host arch]
  --memory <size>            Memory allocation (e.g. 4G, 2048M) [default: 4G]
  --cpus <n>                 CPU core count [default: 2]
  --os <os_type>             Operating system label (e.g. ubuntu, debian, alpine, macos) [default: generic]
  --accel <accel>            Acceleration framework (hvf, tcg) [default: hvf]
  --description <text>       Human-readable description
  --extra-args <args>        Extra arguments to pass to QEMU

${BOLD}Options for 'list':${RESET}
  -j, --json                 Output results as JSON
  -q, --quiet                Output VM names only (one per line)

${BOLD}Options for 'get':${RESET}
  -j, --json                 Output details as JSON

${BOLD}Options for 'update':${RESET}
  --disk <path>              Update disk image path
  --arch <arch>              Update architecture
  --memory <size>            Update memory
  --cpus <n>                 Update CPU cores
  --os <os_type>             Update OS label
  --accel <accel>            Update acceleration
  --status <status>          Update status (e.g. running, stopped)
  --description <text>       Update description
  --extra-args <args>        Update extra QEMU arguments

${BOLD}Options for 'delete':${RESET}
  --delete-disk              Also remove the disk image file from disk
  -f, --force                Do not prompt for confirmation

${BOLD}Exit Codes:${RESET}
  0 - Success
  1 - Command or syntax error
  2 - VM not found
  3 - VM already exists
EOF
}

# Python registry controller helper
run_py_registry() {
  ensure_config_dir
  /usr/bin/python3 - "$REGISTRY_FILE" "$@" << 'PYEOF'
import sys
import os
import json
import datetime
import argparse

registry_path = sys.argv[1]
action = sys.argv[2]
args = sys.argv[3:]

def get_host_arch():
    m = os.uname().machine
    if m in ["arm64", "aarch64"]:
        return "aarch64"
    if m in ["x86_64", "amd64"]:
        return "x86_64"
    return m

def get_utc_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def load_registry():
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
    data["updated_at"] = get_utc_iso()
    os.makedirs(os.path.dirname(os.path.abspath(registry_path)), exist_ok=True)
    temp_file = f"{registry_path}.tmp.{os.getpid()}"
    with open(temp_file, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(temp_file, registry_path)

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

elif action == "add":
    parser = argparse.ArgumentParser(prog="manage-vms add")
    parser.add_argument("name")
    parser.add_argument("--disk", default="")
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

    vm_entry = {
        "name": name,
        "arch": parsed.arch,
        "os": parsed.os,
        "disk": os.path.abspath(parsed.disk) if parsed.disk else "",
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
    print(f"[INFO] Registered VM '{name}' successfully.")
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
        print("No virtual machines registered. Run 'manage-vms.sh add <name>' to register one.")
        sys.exit(0)

    # Print formatted table
    headers = ["NAME", "ARCH", "CPUS", "MEMORY", "STATUS", "OS", "DISK"]
    rows = []
    for name in sorted(vms.keys()):
        v = vms[name]
        disk_str = v.get("disk", "")
        if len(disk_str) > 35:
            disk_str = "..." + disk_str[-32:]
        rows.append([
            v.get("name", name),
            v.get("arch", "unknown"),
            str(v.get("cpus", 2)),
            v.get("memory", "4G"),
            v.get("status", "stopped"),
            v.get("os", "generic"),
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

    print(f"Name:         {vm.get('name')}")
    print(f"Architecture: {vm.get('arch')}")
    print(f"OS:           {vm.get('os')}")
    print(f"CPUs:         {vm.get('cpus')}")
    print(f"Memory:       {vm.get('memory')}")
    print(f"Acceleration: {vm.get('accel')}")
    print(f"Status:       {vm.get('status')}")
    print(f"Disk Image:   {vm.get('disk') or '<none>'}")
    print(f"Description:  {vm.get('description') or '<none>'}")
    print(f"Extra Args:   {vm.get('extra_args') or '<none>'}")
    print(f"Created At:   {vm.get('created_at')}")
    print(f"Updated At:   {vm.get('updated_at')}")
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

elif action == "delete":
    parser = argparse.ArgumentParser(prog="manage-vms delete")
    parser.add_argument("name")
    parser.add_argument("--delete-disk", action="store_true")
    parser.add_argument("-f", "--force", action="store_true")

    parsed = parser.parse_args(args)
    data = load_registry()
    name = parsed.name.strip()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]
    disk_path = vm.get("disk", "")

    if parsed.delete_disk and disk_path and os.path.exists(disk_path):
        try:
            os.remove(disk_path)
            print(f"[INFO] Deleted disk image file: {disk_path}")
        except Exception as e:
            print(f"[WARN] Failed to delete disk image: {e}", file=sys.stderr)

    del data["vms"][name]
    save_registry(data)
    print(f"[INFO] Deleted VM '{name}' from registry.")
    sys.exit(0)

else:
    print(f"[ERROR] Unknown action: {action}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Route commands
if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

COMMAND="$1"
shift

case "$COMMAND" in
  add|create|register)
    run_py_registry "add" "$@"
    ;;
  list|ls)
    run_py_registry "list" "$@"
    ;;
  get|show|info)
    run_py_registry "get" "$@"
    ;;
  update|set)
    run_py_registry "update" "$@"
    ;;
  delete|rm|remove|unregister)
    run_py_registry "delete" "$@"
    ;;
  exists)
    run_py_registry "exists" "$@"
    ;;
  path)
    run_py_registry "path"
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
