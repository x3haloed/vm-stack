#!/usr/bin/env bash
# ==============================================================================
# manage-vms.sh
# Authoritative gateway and wrapper around QEMU and filesystem operations
# for local virtual machines on macOS, Linux, and Windows.
#
# Enforces that all VM disk creation, deletion, resizing, cloning, renaming,
# and runtime execution (start/stop) are bound atomically to
# ~/.config/vm-stack/vms.json.
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
RUN_DIR="$CONFIG_DIR/run"

log_info()  { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$1" >&2; }

show_help() {
  cat << EOF
${BOLD}Usage:${RESET} manage-vms.sh <command> [arguments...]

Authoritative QEMU and Filesystem gateway for vm-stack.
Registry inventory: ${DIM}$REGISTRY_FILE${RESET}
Default images dir: ${DIM}$IMAGES_DIR/${RESET}
Runtime state dir:  ${DIM}$RUN_DIR/${RESET}

${BOLD}QEMU & Disk Management (Bound to Registry):${RESET}
  ${BLUE}create${RESET} <name> [options]         Create a new QEMU disk image and register VM
  ${BLUE}import${RESET} <name> [options]         Inspect an existing disk image and register VM
  ${BLUE}rename${RESET} <old> <new> [options]    Rename VM and move disk image
  ${BLUE}resize${RESET} <name> <size>            Resize VM disk via qemu-img and update registry
  ${BLUE}clone${RESET} <source> <new> [options]  Clone VM (linked overlay or full copy) and register
  ${BLUE}delete${RESET} <name> [options]         Delete VM registry entry and remove disk file
  ${BLUE}snapshot${RESET} <name> <action> [...]    Manage internal disk snapshots (create, list, rollback, delete)

${BOLD}VM Lifecycle & Execution:${RESET}
  ${BLUE}start${RESET} <name> [options]          Start VM with QEMU (foreground, background daemon, or snapshot mode)
  ${BLUE}stop${RESET} <name> [options]           Stop running VM (graceful ACPI shutdown or force kill)
  ${BLUE}status${RESET} <name> [options]         Check live runtime status (process liveness, ports)
  ${BLUE}wait-ready${RESET} <name> [options]     Wait for guest SSH service to become responsive
  ${BLUE}exec${RESET} <name> [options] -- <cmd>   Execute command inside guest via SSH
  ${BLUE}copy-to${RESET} <name> <src> <dest>      Copy local file/directory into guest via SCP
  ${BLUE}copy-from${RESET} <name> <src> <dest>    Copy file/directory from guest to host via SCP
  ${BLUE}send-key${RESET} <name> <key...>          Send a key or key combination through the QEMU monitor
  ${BLUE}type-text${RESET} <name> <text>           Type supported text through the QEMU monitor
  ${BLUE}screenshot${RESET} <name> --output <ppm>  Capture the guest framebuffer through the QEMU monitor
  ${BLUE}run-ephemeral${RESET} <base> -- <cmd>   Start disposable VM with snapshot discard, run command, and stop

${BOLD}Inventory Query & Inspection:${RESET}
  ${BLUE}list${RESET} [options]                  List all registered VMs with live probed status
  ${BLUE}inspect${RESET} <name> [options]        Deep inspection combining registry spec + live disk/process
  ${BLUE}get${RESET} <name> [options]             Get authoritative VM specification from registry
  ${BLUE}update${RESET} <name> [options]          Update VM specification settings
  ${BLUE}exists${RESET} <name>                   Check if a VM is registered (exit 0=yes, 1=no)
  ${BLUE}sync${RESET} [options]                  Audit registry against filesystem & clean dead runtime states
  ${BLUE}path${RESET}                            Print absolute path to the registry file
  ${BLUE}help${RESET}                            Show this help message

${BOLD}Options for 'create':${RESET}
  --size <size>              Virtual disk size (e.g. 20G, 64G) [Required]
  --format <fmt>             Disk format (qcow2, raw) [default: qcow2]
  --disk <path>              Target disk image path [default: images/<name>.<format>]
  --backing-file <path>      Base backing image for copy-on-write
  --arch <arch>              Target architecture (aarch64, x86_64) [default: host arch]
  --memory <size>            Memory allocation (e.g. 4G, 8G) [default: 4G]
  --cpus <n>                 CPU core count [default: 2]
  --os <os_type>             OS label (windows, ubuntu, debian, alpine, generic) [default: generic]
  --accel <accel>            Acceleration framework (hvf, kvm, whpx, tcg) [default: auto]
  --ssh-port <port>          Default host port for SSH forwarding [default: 2222]
  --rdp-port <port>          Default host port for RDP forwarding [default: 3389]
  --description <text>       Human-readable description
  --extra-args <args>        Extra arguments for QEMU execution

${BOLD}Options for 'start':${RESET}
  -d, --daemon, --background Run VM in background process (PID tracked in run/<name>.pid)
  --snapshot, --ephemeral    Discard all disk writes on VM stop (base disk untouched)
  --display <mode>           Display mode (default, cocoa, gtk, vnc, none) [default: default]
  --ssh-port <port>          Override host SSH forward port
  --rdp-port <port>          Override host RDP forward port
  --memory <size>            Override RAM allocation for this run
  --cpus <n>                 Override CPU core count for this run
  --extra-args <args>        Additional QEMU arguments for this invocation
  --dry-run                  Print assembled QEMU command without executing

${BOLD}Options for 'exec':${RESET}
  manage-vms.sh exec <name> [--user <user>] [--password <pass>] [--timeout <sec>] -- <cmd...>

${BOLD}Options for 'stop':${RESET}
  -f, --force                Force immediate termination (SIGKILL) instead of graceful SIGTERM

${BOLD}Options for 'snapshot':${RESET}
  manage-vms.sh snapshot <name> create <snapname>
  manage-vms.sh snapshot <name> list [-j/--json]
  manage-vms.sh snapshot <name> rollback <snapname>
  manage-vms.sh snapshot <name> delete <snapname>

${BOLD}Options for 'inspect' / 'status' / 'list' / 'get':${RESET}
  -j, --json                 Output machine-readable JSON format
  -q, --quiet                Output VM names only (for 'list')

${BOLD}Exit Codes:${RESET}
  0 - Success
  1 - Command or execution error
  2 - VM not found
  3 - VM already exists
EOF
}

# Python core engine executing atomic QEMU and filesystem operations
run_py_gateway() {
  /usr/bin/python3 - "$CONFIG_DIR" "$REGISTRY_FILE" "$IMAGES_DIR" "$RUN_DIR" "$@" << 'PYEOF'
import sys
import os
import json
import subprocess
import datetime
import argparse
import shutil
import shlex
import signal
import time
import socket

config_dir = sys.argv[1]
registry_path = sys.argv[2]
images_dir = sys.argv[3]
run_dir = sys.argv[4]
action = sys.argv[5]
args = sys.argv[6:]

# ──────────────────────────────────────────────────────────────────────────
# Utility Functions
# ──────────────────────────────────────────────────────────────────────────

def get_host_arch():
    m = os.uname().machine.lower()
    if m in ["arm64", "aarch64"]:
        return "aarch64"
    if m in ["x86_64", "amd64"]:
        return "x86_64"
    return m

def get_default_accel():
    uname_s = os.uname().sysname.lower()
    if uname_s == "darwin":
        return "hvf"
    elif uname_s == "linux":
        return "kvm"
    elif "windows" in uname_s or "nt" in uname_s:
        return "whpx"
    return "tcg"

def get_utc_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def ensure_dirs():
    for d in [config_dir, images_dir, run_dir]:
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass

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
# Dynamic Probing (Disk & Runtime)
# ──────────────────────────────────────────────────────────────────────────

def probe_disk_info(disk_path):
    """Probes disk properties dynamically via qemu-img info."""
    if not disk_path or not os.path.exists(disk_path):
        return {
            "exists": False,
            "path": disk_path or "",
            "actual_size_bytes": 0,
            "actual_size": "missing",
            "virtual_size_bytes": 0,
            "virtual_size": "missing",
            "format": "unknown",
            "backing_file": None,
            "snapshots": []
        }

    try:
        res = subprocess.run(
            ["qemu-img", "info", "--force-share", "--output=json", disk_path],
            capture_output=True,
            text=True,
            check=True
        )
        data = json.loads(res.stdout)
        actual_bytes = os.path.getsize(disk_path)
        v_bytes = data.get("virtual-size", 0)
        return {
            "exists": True,
            "path": disk_path,
            "actual_size_bytes": actual_bytes,
            "actual_size": format_size(actual_bytes),
            "virtual_size_bytes": v_bytes,
            "virtual_size": format_size(v_bytes),
            "format": data.get("format", "qcow2"),
            "backing_file": data.get("backing-filename"),
            "snapshots": [s.get("name") for s in data.get("snapshots", [])]
        }
    except Exception as e:
        actual_bytes = os.path.getsize(disk_path) if os.path.exists(disk_path) else 0
        return {
            "exists": True,
            "path": disk_path,
            "actual_size_bytes": actual_bytes,
            "actual_size": format_size(actual_bytes),
            "virtual_size_bytes": 0,
            "virtual_size": "unknown",
            "format": "unknown",
            "backing_file": None,
            "snapshots": []
        }

def get_pid_file_path(vm_name):
    return os.path.join(run_dir, f"{vm_name}.pid")

def get_qmp_socket_path(vm_name):
    return os.path.join(run_dir, f"{vm_name}.qmp")

def qmp_execute(vm_name, command, arguments=None, timeout=2.0):
    qmp_path = get_qmp_socket_path(vm_name)
    if not os.path.exists(qmp_path):
        raise RuntimeError(f"QMP socket is not available for VM '{vm_name}'")

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(qmp_path)
        stream = conn.makefile("rwb", buffering=0)
        json.loads(stream.readline().decode("utf-8"))
        stream.write((json.dumps({"execute": "qmp_capabilities"}) + "\n").encode("utf-8"))
        while True:
            response = json.loads(stream.readline().decode("utf-8"))
            if "return" in response or "error" in response:
                break
        request = {"execute": command}
        if arguments:
            request["arguments"] = arguments
        stream.write((json.dumps(request) + "\n").encode("utf-8"))
        while True:
            response = json.loads(stream.readline().decode("utf-8"))
            if "return" in response:
                return response["return"]
            if "error" in response:
                raise RuntimeError(response["error"].get("desc", str(response["error"])))

def is_process_running(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def check_ssh_service(port, host="127.0.0.1", timeout=0.5):
    if not port:
        return False
    try:
        with socket.create_connection((host, int(port)), timeout=timeout) as conn:
            # QEMU user networking accepts the forwarded TCP connection even
            # before a guest is listening. Require the SSH identification
            # string so runtime readiness reflects the guest service itself.
            banner = b""
            while len(banner) < 255 and b"\n" not in banner:
                chunk = conn.recv(255 - len(banner))
                if not chunk:
                    break
                banner += chunk
            return banner.startswith(b"SSH-")
    except Exception:
        return False

def probe_vm_runtime(vm_name, disk_path=None, ssh_port=None):
    """Probes live runtime state for a given VM."""
    pid_file = get_pid_file_path(vm_name)
    pid = None
    if os.path.exists(pid_file):
        try:
            with open(pid_file, "r") as f:
                content = f.read().strip()
                if content.isdigit():
                    pid = int(content)
        except Exception:
            pid = None

    is_alive = False
    if pid and is_process_running(pid):
        is_alive = True
    elif pid and not is_process_running(pid):
        # Process died, clean up stale pid file
        try:
            os.remove(pid_file)
        except Exception:
            pass
        pid = None

    # Fallback: scan process list if pid file missing
    if not is_alive and disk_path and os.path.exists(disk_path):
        try:
            ps_out = subprocess.run(["ps", "-ax", "-o", "pid,command"], capture_output=True, text=True).stdout
            for line in ps_out.splitlines():
                if "qemu-system" in line and os.path.basename(disk_path) in line:
                    parts = line.strip().split(None, 1)
                    if parts and parts[0].isdigit():
                        found_pid = int(parts[0])
                        if is_process_running(found_pid):
                            pid = found_pid
                            is_alive = True
                            # write back recovered pid
                            try:
                                with open(pid_file, "w") as f:
                                    f.write(f"{pid}\n")
                            except Exception:
                                pass
                            break
        except Exception:
            pass

    ssh_ready = False
    if is_alive and ssh_port:
        ssh_ready = check_ssh_service(ssh_port)

    status_str = "running" if is_alive else "stopped"
    return {
        "status": status_str,
        "is_running": is_alive,
        "pid": pid if is_alive else None,
        "ssh_ready": ssh_ready if is_alive else False
    }

def synthesize_vm_info(vm_spec):
    """Combines authoritative spec with live disk and runtime probes."""
    name = vm_spec["name"]
    disk_path = vm_spec.get("disk", "")
    ssh_port = vm_spec.get("ssh_port")

    disk_info = probe_disk_info(disk_path)
    runtime_info = probe_vm_runtime(name, disk_path, ssh_port)

    return {
        "name": name,
        "arch": vm_spec.get("arch", get_host_arch()),
        "os": vm_spec.get("os", "generic"),
        "cpus": vm_spec.get("cpus", 2),
        "memory": vm_spec.get("memory", "4G"),
        "accel": vm_spec.get("accel", get_default_accel()),
        "ssh_port": vm_spec.get("ssh_port", 2222),
        "rdp_port": vm_spec.get("rdp_port", 3389),
        "extra_args": vm_spec.get("extra_args", ""),
        "description": vm_spec.get("description", ""),
        "created_at": vm_spec.get("created_at"),
        "updated_at": vm_spec.get("updated_at"),
        "disk": disk_info,
        "runtime": runtime_info
    }

# ──────────────────────────────────────────────────────────────────────────
# Actions
# ──────────────────────────────────────────────────────────────────────────

if action == "path":
    print(os.path.abspath(registry_path))
    sys.exit(0)

elif action == "exists":
    if len(args) < 1:
        sys.exit(1)
    name = args[0].strip()
    data = load_registry()
    sys.exit(0 if name in data["vms"] else 1)

elif action == "create":
    parser = argparse.ArgumentParser(prog="manage-vms create")
    parser.add_argument("name")
    parser.add_argument("--size", required=True, help="Virtual disk size, e.g. 20G, 64G")
    parser.add_argument("--format", default="qcow2", choices=["qcow2", "raw"])
    parser.add_argument("--disk", default="")
    parser.add_argument("--backing-file", default="")
    parser.add_argument("--arch", default=get_host_arch())
    parser.add_argument("--memory", default="4G")
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--os", default="generic")
    parser.add_argument("--accel", default="auto")
    parser.add_argument("--ssh-port", type=int, default=2222)
    parser.add_argument("--rdp-port", type=int, default=3389)
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

    # 1. Allocate disk image via qemu-img
    cmd = ["qemu-img", "create", "-f", parsed.format]
    if parsed.backing_file:
        backing_abs = os.path.abspath(parsed.backing_file)
        if not os.path.exists(backing_abs):
            print(f"[ERROR] Backing file not found: {parsed.backing_file}", file=sys.stderr)
            sys.exit(1)
        cmd.extend(["-b", backing_abs, "-F", "qcow2"])
    cmd.extend([disk_path, parsed.size])

    try:
        print(f"[INFO] Creating QEMU disk: {' '.join(cmd)}")
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] qemu-img create failed with code {e.returncode}.", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("[ERROR] 'qemu-img' command not found in PATH.", file=sys.stderr)
        sys.exit(1)

    # 2. Bind authoritative VM specification to registry
    accel_val = get_default_accel() if parsed.accel == "auto" else parsed.accel
    vm_spec = {
        "name": name,
        "disk": disk_path,
        "os": parsed.os,
        "arch": parsed.arch,
        "cpus": parsed.cpus,
        "memory": parsed.memory,
        "accel": accel_val,
        "ssh_port": parsed.ssh_port,
        "rdp_port": parsed.rdp_port,
        "extra_args": parsed.extra_args,
        "description": parsed.description,
        "created_at": get_utc_iso(),
        "updated_at": get_utc_iso()
    }

    data["vms"][name] = vm_spec
    save_registry(data)

    print(f"[INFO] Successfully created disk and registered VM '{name}' in inventory.")
    sys.exit(0)

elif action == "import":
    parser = argparse.ArgumentParser(prog="manage-vms import")
    parser.add_argument("name")
    parser.add_argument("--disk", required=True)
    parser.add_argument("--arch", default=get_host_arch())
    parser.add_argument("--memory", default="4G")
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--os", default="generic")
    parser.add_argument("--accel", default="auto")
    parser.add_argument("--ssh-port", type=int, default=2222)
    parser.add_argument("--rdp-port", type=int, default=3389)
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

    accel_val = get_default_accel() if parsed.accel == "auto" else parsed.accel
    vm_spec = {
        "name": name,
        "disk": disk_path,
        "os": parsed.os,
        "arch": parsed.arch,
        "cpus": parsed.cpus,
        "memory": parsed.memory,
        "accel": accel_val,
        "ssh_port": parsed.ssh_port,
        "rdp_port": parsed.rdp_port,
        "extra_args": parsed.extra_args,
        "description": parsed.description,
        "created_at": get_utc_iso(),
        "updated_at": get_utc_iso()
    }

    data["vms"][name] = vm_spec
    save_registry(data)
    print(f"[INFO] Imported and registered VM '{name}' ({disk_path}).")
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

    # Check if old VM is running
    rt = probe_vm_runtime(old_name)
    if rt["is_running"]:
        print(f"[ERROR] Cannot rename VM '{old_name}' while it is running (PID: {rt['pid']}). Please stop it first.", file=sys.stderr)
        sys.exit(1)

    vm = data["vms"][old_name]
    old_disk = vm.get("disk", "")
    new_disk = old_disk

    should_rename_disk = parsed.rename_disk
    if should_rename_disk is None:
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

    # Rename nvram vars file if present
    old_vars = os.path.join(images_dir, f"{old_name}_vars.fd")
    new_vars = os.path.join(images_dir, f"{new_name}_vars.fd")
    if os.path.exists(old_vars):
        try:
            shutil.move(old_vars, new_vars)
        except Exception:
            pass

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

    vm["updated_at"] = get_utc_iso()
    save_registry(data)
    disk_info = probe_disk_info(disk_path)
    print(f"[INFO] Resized VM '{name}' disk to {disk_info['virtual_size']}.")
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
        cmd = ["qemu-img", "convert", "-O", "qcow2", src_disk, target_disk]
        clone_type = "Full standalone clone"
    else:
        cmd = ["qemu-img", "create", "-f", "qcow2", "-b", src_disk, "-F", "qcow2", target_disk]
        clone_type = "Linked overlay clone"

    try:
        print(f"[INFO] Running: {' '.join(cmd)}")
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] qemu-img failed during clone: code {e.returncode}.", file=sys.stderr)
        sys.exit(1)

    # Pick non-conflicting SSH port for clone
    existing_ports = [v.get("ssh_port", 2222) for v in data["vms"].values()]
    new_ssh_port = src_vm.get("ssh_port", 2222) + 1
    while new_ssh_port in existing_ports:
        new_ssh_port += 1

    new_vm = {
        "name": new_name,
        "disk": target_disk,
        "os": src_vm.get("os", "generic"),
        "arch": src_vm.get("arch", get_host_arch()),
        "cpus": src_vm.get("cpus", 2),
        "memory": src_vm.get("memory", "4G"),
        "accel": src_vm.get("accel", get_default_accel()),
        "ssh_port": new_ssh_port,
        "rdp_port": src_vm.get("rdp_port", 3389) + 1,
        "extra_args": src_vm.get("extra_args", ""),
        "description": parsed.description or f"Clone of {src_name}",
        "created_at": get_utc_iso(),
        "updated_at": get_utc_iso()
    }

    data["vms"][new_name] = new_vm
    save_registry(data)
    print(f"[INFO] {clone_type} '{new_name}' created from '{src_name}' (SSH port: {new_ssh_port}).")
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

    # If running, stop or error
    rt = probe_vm_runtime(name, data["vms"][name].get("disk"))
    if rt["is_running"]:
        if parsed.force:
            print(f"[INFO] VM '{name}' is running (PID {rt['pid']}). Terminating...")
            try:
                os.kill(rt["pid"], signal.SIGKILL)
            except Exception:
                pass
        else:
            print(f"[ERROR] VM '{name}' is currently running (PID: {rt['pid']}). Stop it first or pass --force.", file=sys.stderr)
            sys.exit(1)

    vm = data["vms"][name]
    disk_path = vm.get("disk", "")

    if not parsed.keep_disk and disk_path and os.path.exists(disk_path):
        try:
            print(f"[INFO] Removing disk file: {disk_path}")
            os.remove(disk_path)
        except Exception as e:
            print(f"[WARN] Could not remove disk file: {e}", file=sys.stderr)

    # Clean up associated vars and pid files
    vars_file = os.path.join(images_dir, f"{name}_vars.fd")
    if os.path.exists(vars_file):
        try: os.remove(vars_file)
        except Exception: pass

    pid_file = get_pid_file_path(name)
    if os.path.exists(pid_file):
        try: os.remove(pid_file)
        except Exception: pass

    del data["vms"][name]
    save_registry(data)
    print(f"[INFO] Deleted VM '{name}' from inventory.")
    sys.exit(0)

elif action == "start":
    parser = argparse.ArgumentParser(prog="manage-vms start")
    parser.add_argument("name")
    parser.add_argument("-d", "--daemon", "--background", dest="daemon", action="store_true")
    parser.add_argument("--snapshot", "--ephemeral", dest="snapshot", action="store_true", help="Write changes to temporary files and discard on exit")
    parser.add_argument("--display", default="default", choices=["default", "cocoa", "gtk", "vnc", "none"])
    parser.add_argument("--ssh-port", type=int, default=None)
    parser.add_argument("--rdp-port", type=int, default=None)
    parser.add_argument("--memory", default=None)
    parser.add_argument("--cpus", type=int, default=None)
    parser.add_argument("--extra-args", default="")
    parser.add_argument("--dry-run", action="store_true")

    parsed = parser.parse_args(args)
    data = load_registry()
    name = parsed.name.strip()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]
    disk_path = vm.get("disk", "")
    if not disk_path or not os.path.exists(disk_path):
        print(f"[ERROR] Disk image for VM '{name}' not found: {disk_path}", file=sys.stderr)
        sys.exit(1)

    # Pre-check if already running
    rt = probe_vm_runtime(name, disk_path)
    if rt["is_running"]:
        print(f"[WARN] VM '{name}' is already running (PID: {rt['pid']}).")
        sys.exit(0)

    arch = vm.get("arch", get_host_arch())
    qemu_bin = f"qemu-system-{arch}"
    if not shutil.which(qemu_bin):
        print(f"[ERROR] Emulator binary '{qemu_bin}' not found in PATH.", file=sys.stderr)
        sys.exit(1)

    memory = parsed.memory or vm.get("memory", "4G")
    cpus = str(parsed.cpus or vm.get("cpus", 2))
    accel = vm.get("accel", get_default_accel())
    ssh_p = parsed.ssh_port or vm.get("ssh_port", 2222)
    rdp_p = parsed.rdp_port or vm.get("rdp_port", 3389)
    network_device = "virtio-net-pci"

    # Assemble base command
    qmp_path = get_qmp_socket_path(name)
    if os.path.exists(qmp_path):
        os.remove(qmp_path)
    cmd = [
        qemu_bin,
        "-accel", accel,
        "-cpu", "host" if accel in ["hvf", "kvm", "whpx"] else "max",
        "-smp", str(cpus),
        "-m", str(memory),
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-kbd",
        "-device", "usb-tablet",
        "-drive", f"file={disk_path},if=none,id=hd0,format=qcow2",
        "-device", "nvme,drive=hd0,serial=nvme0,bootindex=0",
        "-netdev", f"user,id=net0,hostfwd=tcp::{ssh_p}-:22,hostfwd=tcp::{rdp_p}-:3389",
        "-device", f"{network_device},netdev=net0",
        "-qmp", f"unix:{qmp_path},server=on,wait=off"
    ]

    if parsed.snapshot:
        cmd.append("-snapshot")

    # Arch-specific machine & firmware
    if arch == "aarch64":
        cmd.extend(["-M", "virt,highmem=on", "-device", "ramfb"])
        # Check for UEFI vars
        vars_file = os.path.join(images_dir, f"{name}_vars.fd")
        edk2_code = None
        for p in ["/opt/homebrew/share/qemu/edk2-aarch64-code.fd", "/usr/share/qemu/edk2-aarch64-code.fd", "/usr/local/share/qemu/edk2-aarch64-code.fd"]:
            if os.path.exists(p):
                edk2_code = p
                break
        if edk2_code:
            cmd.extend(["-drive", f"if=pflash,format=raw,readonly=on,file={edk2_code}"])
            if os.path.exists(vars_file):
                cmd.extend(["-drive", f"if=pflash,format=raw,file={vars_file}"])
    else:
        cmd.extend(["-M", "q35,smm=on", "-device", "virtio-vga"])
        vars_file = os.path.join(images_dir, f"{name}_vars.fd")
        edk2_code = None
        for p in ["/opt/homebrew/share/qemu/edk2-x86_64-code.fd", "/usr/share/qemu/edk2-x86_64-code.fd", "/usr/local/share/qemu/edk2-x86_64-code.fd"]:
            if os.path.exists(p):
                edk2_code = p
                break
        if edk2_code:
            cmd.extend(["-drive", f"if=pflash,format=raw,readonly=on,file={edk2_code}"])
            if os.path.exists(vars_file):
                cmd.extend(["-drive", f"if=pflash,format=raw,file={vars_file}"])

    # Display configuration
    disp = parsed.display
    if disp == "none":
        cmd.extend(["-display", "none"])
    elif disp == "vnc":
        cmd.extend(["-display", "none", "-vnc", ":0"])
    elif disp == "cocoa":
        cmd.extend(["-display", "cocoa,show-cursor=on"])
    elif disp == "gtk":
        cmd.extend(["-display", "gtk,show-cursor=on"])
    else:
        cmd.extend(["-display", "default,show-cursor=on"])

    # Extra arguments from spec or cli
    combined_extra = f"{vm.get('extra_args', '')} {parsed.extra_args}".strip()
    if combined_extra:
        cmd.extend(shlex.split(combined_extra))

    if parsed.dry_run:
        print("[INFO] Assembled QEMU launch command (dry-run):")
        print(f"\n    {' '.join(cmd)}\n")
        sys.exit(0)

    print(f"[INFO] Starting VM '{name}' ({arch}, {memory} RAM, {cpus} CPUs, SSH: localhost:{ssh_p})...")

    pid_file = get_pid_file_path(name)

    if parsed.daemon or disp == "none":
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True
        )
        with open(pid_file, "w") as f:
            f.write(f"{proc.pid}\n")
        print(f"[INFO] VM '{name}' started in background (PID: {proc.pid}).")
        sys.exit(0)
    else:
        # Foreground execution
        try:
            proc = subprocess.Popen(cmd)
            with open(pid_file, "w") as f:
                f.write(f"{proc.pid}\n")
            proc.wait()
        finally:
            if os.path.exists(pid_file):
                try: os.remove(pid_file)
                except Exception: pass
            if os.path.exists(qmp_path):
                try: os.remove(qmp_path)
                except Exception: pass
        sys.exit(0)

elif action == "send-key":
    parser = argparse.ArgumentParser(prog="manage-vms send-key")
    parser.add_argument("name")
    parser.add_argument("key", nargs="+", help="One or more simultaneous QEMU key names")
    parsed = parser.parse_args(args)

    data = load_registry()
    name = parsed.name.strip()
    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)
    try:
        qmp_execute(name, "send-key", {"keys": [{"type": "qcode", "data": key} for key in parsed.key]})
        print(f"[INFO] Sent key combination '{'+'.join(parsed.key)}' to VM '{name}'.")
        sys.exit(0)
    except Exception as e:
        print(f"[ERROR] Could not send key to VM '{name}': {e}", file=sys.stderr)
        sys.exit(1)

elif action == "type-text":
    parser = argparse.ArgumentParser(prog="manage-vms type-text")
    parser.add_argument("name")
    parser.add_argument("text")
    parser.add_argument("--enter", action="store_true")
    parsed = parser.parse_args(args)

    data = load_registry()
    name = parsed.name.strip()
    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    punctuation = {
        "\\": ["backslash"], ".": ["dot"], "-": ["minus"], "_": ["shift", "minus"],
        ":": ["shift", "semicolon"], ";": ["semicolon"], "|": ["shift", "backslash"],
        "~": ["shift", "grave_accent"], "/": ["slash"], " ": ["spc"]
    }
    try:
        key_sequences = []
        for char in parsed.text:
            if char.isalpha():
                keys = ["shift", char.lower()] if char.isupper() else [char]
            elif char.isdigit():
                keys = [char]
            elif char in punctuation:
                keys = punctuation[char]
            else:
                raise RuntimeError(f"Unsupported character for QMP typing: {char!r}")
            key_sequences.append(keys)
        for keys in key_sequences:
            qmp_execute(name, "send-key", {"keys": [{"type": "qcode", "data": key} for key in keys]})
            time.sleep(0.02)
        if parsed.enter:
            qmp_execute(name, "send-key", {"keys": [{"type": "qcode", "data": "ret"}]})
        print(f"[INFO] Typed text into VM '{name}'.")
        sys.exit(0)
    except Exception as e:
        print(f"[ERROR] Could not type text into VM '{name}': {e}", file=sys.stderr)
        sys.exit(1)

elif action == "screenshot":
    parser = argparse.ArgumentParser(prog="manage-vms screenshot")
    parser.add_argument("name")
    parser.add_argument("--output", required=True, help="Destination PPM image path")
    parsed = parser.parse_args(args)

    data = load_registry()
    name = parsed.name.strip()
    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)
    output_path = os.path.abspath(os.path.expanduser(parsed.output))
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    try:
        qmp_execute(name, "screendump", {"filename": output_path})
        print(output_path)
        sys.exit(0)
    except Exception as e:
        print(f"[ERROR] Could not capture VM '{name}': {e}", file=sys.stderr)
        sys.exit(1)

elif action == "stop":
    parser = argparse.ArgumentParser(prog="manage-vms stop")
    parser.add_argument("name")
    parser.add_argument("-f", "--force", action="store_true")

    parsed = parser.parse_args(args)
    name = parsed.name.strip()
    data = load_registry()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    rt = probe_vm_runtime(name, data["vms"][name].get("disk"))
    if not rt["is_running"] or not rt["pid"]:
        print(f"[INFO] VM '{name}' is already stopped.")
        sys.exit(0)

    pid = rt["pid"]
    sig = signal.SIGKILL if parsed.force else signal.SIGTERM
    action_word = "Killing" if parsed.force else "Gracefully stopping"

    print(f"[INFO] {action_word} VM '{name}' (PID: {pid})...")
    try:
        os.kill(pid, sig)
        # Wait up to 5 seconds for termination
        for _ in range(25):
            if not is_process_running(pid):
                break
            time.sleep(0.2)
        if is_process_running(pid) and not parsed.force:
            print("[WARN] VM did not terminate within timeout. Forcing termination...")
            os.kill(pid, signal.SIGKILL)
    except Exception as e:
        print(f"[ERROR] Could not send signal to process: {e}", file=sys.stderr)
        sys.exit(1)

    pid_file = get_pid_file_path(name)
    if os.path.exists(pid_file):
        try: os.remove(pid_file)
        except Exception: pass

    print(f"[INFO] VM '{name}' is now stopped.")
    sys.exit(0)

elif action == "status":
    parser = argparse.ArgumentParser(prog="manage-vms status")
    parser.add_argument("name")
    parser.add_argument("-j", "--json", action="store_true")
    parsed = parser.parse_args(args)

    data = load_registry()
    name = parsed.name.strip()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    info = synthesize_vm_info(data["vms"][name])

    if parsed.json:
        print(json.dumps(info, indent=2))
        sys.exit(0)

    rt = info["runtime"]
    disk = info["disk"]
    status_label = f"\033[32mRUNNING (PID: {rt['pid']})\033[0m" if rt["is_running"] else "\033[33mSTOPPED\033[0m"

    print(f"VM Name:         {info['name']}")
    print(f"Status:          {status_label}")
    print(f"SSH Reachable:   {'Yes (localhost:' + str(info['ssh_port']) + ')' if rt.get('ssh_ready') else 'No / Port closed'}")
    print(f"Architecture:    {info['arch']}")
    print(f"Hardware:        {info['cpus']} vCPUs, {info['memory']} RAM")
    print(f"Disk Image:      {disk['path']}")
    print(f"Disk Exists:     {'Yes' if disk['exists'] else 'NO (Missing)'}")
    print(f"Disk Size:       {disk['actual_size']} (virtual: {disk['virtual_size']}, fmt: {disk['format']})")
    if disk.get("snapshots"):
        print(f"Snapshots:       {', '.join(disk['snapshots'])}")
    sys.exit(0)

elif action == "snapshot":
    if len(args) < 2:
        print("[ERROR] Usage: manage-vms.sh snapshot <name> <create|list|rollback|delete> [snapname]", file=sys.stderr)
        sys.exit(1)

    name = args[0].strip()
    subaction = args[1].strip().lower()
    data = load_registry()

    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    disk_path = data["vms"][name].get("disk", "")
    if not disk_path or not os.path.exists(disk_path):
        print(f"[ERROR] Disk image for VM '{name}' does not exist: {disk_path}", file=sys.stderr)
        sys.exit(1)

    if subaction in ["create", "add", "take"]:
        if len(args) < 3:
            print("[ERROR] Usage: manage-vms.sh snapshot <name> create <snapname>", file=sys.stderr)
            sys.exit(1)
        snapname = args[2].strip()
        cmd = ["qemu-img", "snapshot", "-c", snapname, disk_path]
        print(f"[INFO] Creating snapshot '{snapname}' on VM '{name}'...")
        subprocess.run(cmd, check=True)
        print(f"[INFO] Snapshot '{snapname}' created successfully.")
        sys.exit(0)

    elif subaction in ["list", "ls"]:
        info = probe_disk_info(disk_path)
        if "-j" in args or "--json" in args:
            print(json.dumps(info.get("snapshots", []), indent=2))
        else:
            snaps = info.get("snapshots", [])
            if not snaps:
                print(f"No internal snapshots found for VM '{name}'.")
            else:
                print(f"Snapshots for VM '{name}':")
                for s in snaps:
                    print(f"  • {s}")
        sys.exit(0)

    elif subaction in ["rollback", "apply", "revert"]:
        if len(args) < 3:
            print("[ERROR] Usage: manage-vms.sh snapshot <name> rollback <snapname>", file=sys.stderr)
            sys.exit(1)
        snapname = args[2].strip()
        rt = probe_vm_runtime(name, disk_path)
        if rt["is_running"]:
            print(f"[ERROR] Cannot rollback snapshot while VM is running (PID: {rt['pid']}). Stop it first.", file=sys.stderr)
            sys.exit(1)
        cmd = ["qemu-img", "snapshot", "-a", snapname, disk_path]
        print(f"[INFO] Rolling back VM '{name}' to snapshot '{snapname}'...")
        subprocess.run(cmd, check=True)
        print(f"[INFO] Rollback to snapshot '{snapname}' complete.")
        sys.exit(0)

    elif subaction in ["delete", "rm"]:
        if len(args) < 3:
            print("[ERROR] Usage: manage-vms.sh snapshot <name> delete <snapname>", file=sys.stderr)
            sys.exit(1)
        snapname = args[2].strip()
        cmd = ["qemu-img", "snapshot", "-d", snapname, disk_path]
        print(f"[INFO] Deleting snapshot '{snapname}' from VM '{name}'...")
        subprocess.run(cmd, check=True)
        print(f"[INFO] Deleted snapshot '{snapname}'.")
        sys.exit(0)

    else:
        print(f"[ERROR] Unknown snapshot action: {subaction}", file=sys.stderr)
        sys.exit(1)

elif action == "list":
    parser = argparse.ArgumentParser(prog="manage-vms list")
    parser.add_argument("-j", "--json", action="store_true")
    parser.add_argument("-q", "--quiet", action="store_true")
    parsed = parser.parse_args(args)

    data = load_registry()
    vms = data["vms"]

    if parsed.quiet:
        for name in sorted(vms.keys()):
            print(name)
        sys.exit(0)

    synthesized_list = [synthesize_vm_info(spec) for spec in vms.values()]

    if parsed.json:
        print(json.dumps(synthesized_list, indent=2))
        sys.exit(0)

    if not vms:
        print("No virtual machines registered in inventory. Run 'manage-vms.sh create <name> --size <size>' to create one.")
        sys.exit(0)

    headers = ["NAME", "ARCH", "CPUS", "MEM", "VSIZE", "STATUS", "SSH", "DISK"]
    rows = []
    for info in sorted(synthesized_list, key=lambda x: x["name"]):
        rt = info["runtime"]
        status_text = f"RUNNING ({rt['pid']})" if rt["is_running"] else "STOPPED"
        if not info["disk"]["exists"]:
            status_text = "MISSING DISK"

        disk_str = info["disk"]["path"]
        if len(disk_str) > 28:
            disk_str = "..." + disk_str[-25:]

        ssh_label = f":{info['ssh_port']}" if rt["is_running"] else f":{info['ssh_port']} (off)"

        rows.append([
            info["name"],
            info["arch"],
            str(info["cpus"]),
            info["memory"],
            info["disk"]["virtual_size"],
            status_text,
            ssh_label,
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

    info = synthesize_vm_info(data["vms"][name])

    if parsed.json:
        print(json.dumps(info, indent=2))
        sys.exit(0)

    rt = info["runtime"]
    disk = info["disk"]
    status_label = f"RUNNING (PID: {rt['pid']})" if rt["is_running"] else "STOPPED"

    print(f"VM Name:           {info['name']}")
    print(f"Status:            {status_label}")
    print(f"Architecture:      {info['arch']}")
    print(f"OS Profile:        {info['os']}")
    print(f"Allocated vCPUs:   {info['cpus']}")
    print(f"Allocated Memory:  {info['memory']}")
    print(f"Acceleration:      {info['accel']}")
    print(f"Forwarded SSH:     localhost:{info['ssh_port']} (Ready: {'Yes' if rt['ssh_ready'] else 'No'})")
    print(f"Forwarded RDP:     localhost:{info['rdp_port']}")
    print(f"Disk Image:        {disk['path']}")
    print(f"Disk Exists:       {'Yes' if disk['exists'] else 'NO (Missing)'}")
    print(f"Actual Disk Size:  {disk['actual_size']}")
    print(f"Virtual Disk Size: {disk['virtual_size']}")
    print(f"Disk Format:       {disk['format']}")
    print(f"Backing File:      {disk['backing_file'] or '<none>'}")
    if disk.get("snapshots"):
        print(f"Internal Snaps:    {', '.join(disk['snapshots'])}")
    print(f"Description:       {info['description'] or '<none>'}")
    print(f"Extra Args:        {info['extra_args'] or '<none>'}")
    print(f"Created:           {info['created_at']}")
    print(f"Updated:           {info['updated_at']}")
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

    for k, v in vm.items():
        print(f"{k:<18}: {v}")
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
    parser.add_argument("--ssh-port", type=int, default=None)
    parser.add_argument("--rdp-port", type=int, default=None)
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
    if parsed.ssh_port is not None:
        vm["ssh_port"] = parsed.ssh_port
        updated_fields.append("ssh_port")
    if parsed.rdp_port is not None:
        vm["rdp_port"] = parsed.rdp_port
        updated_fields.append("rdp_port")
    if parsed.description is not None:
        vm["description"] = parsed.description
        updated_fields.append("description")
    if parsed.extra_args is not None:
        vm["extra_args"] = parsed.extra_args
        updated_fields.append("extra_args")

    vm["updated_at"] = get_utc_iso()
    save_registry(data)
    print(f"[INFO] Updated VM '{name}' specification ({', '.join(updated_fields) if updated_fields else 'no changes'}).")
    sys.exit(0)

elif action == "sync":
    parser = argparse.ArgumentParser(prog="manage-vms sync")
    parser.add_argument("--prune", action="store_true")
    parsed = parser.parse_args(args)

    data = load_registry()
    vms = data["vms"]
    changes = 0
    to_delete = []

    print(f"[INFO] Auditing {len(vms)} registered VM(s) against filesystem...")

    for name, vm in vms.items():
        disk = vm.get("disk", "")
        if not disk or not os.path.exists(disk):
            print(f"  [WARN] VM '{name}': Disk missing ({disk})")
            if parsed.prune:
                to_delete.append(name)
        # Clean stale pid files
        pid_file = get_pid_file_path(name)
        if os.path.exists(pid_file):
            try:
                with open(pid_file, "r") as f:
                    c = f.read().strip()
                    if not c.isdigit() or not is_process_running(int(c)):
                        os.remove(pid_file)
                        print(f"  [INFO] Cleaned stale PID file for '{name}'.")
            except Exception:
                pass

    if to_delete:
        for name in to_delete:
            del data["vms"][name]
            changes += 1
            print(f"  [INFO] Pruned VM '{name}' from inventory.")

    if changes > 0:
        save_registry(data)
        print(f"[INFO] Reconciled inventory: {changes} change(s) saved.")
    else:
        print("[INFO] Inventory is in sync with filesystem.")
    sys.exit(0)

elif action in ["wait-ready", "wait-ssh"]:
    parser = argparse.ArgumentParser(prog="manage-vms wait-ready")
    parser.add_argument("name")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--port", type=int, default=None)
    parsed = parser.parse_args(args)

    data = load_registry()
    name = parsed.name.strip()
    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]
    port = parsed.port or vm.get("ssh_port", 2222)
    timeout = parsed.timeout
    start_time = time.time()

    print(f"[INFO] Waiting for VM '{name}' SSH port {port} (timeout: {timeout}s)...")
    while time.time() - start_time < timeout:
        rt = probe_vm_runtime(name, vm.get("disk"), port)
        if rt["ssh_ready"]:
            print(f"[INFO] VM '{name}' is ready (SSH port {port} reachable).")
            sys.exit(0)
        time.sleep(2)

    print(f"[ERROR] Timed out waiting for VM '{name}' after {timeout} seconds.", file=sys.stderr)
    sys.exit(1)

elif action in ["exec", "ssh"]:
    split_idx = -1
    for i, a in enumerate(args):
        if a == "--":
            split_idx = i
            break

    if split_idx != -1:
        flag_args = args[:split_idx]
        cmd_args = args[split_idx + 1:]
    else:
        flag_args = args[:1]
        cmd_args = args[1:]

    parser = argparse.ArgumentParser(prog="manage-vms exec")
    parser.add_argument("name")
    parser.add_argument("--user", default=None)
    parser.add_argument("--password", default=None)
    parser.add_argument("--key", default=None)
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--timeout", type=int, default=120)
    parsed = parser.parse_args(flag_args)

    if not cmd_args:
        print("[ERROR] No command specified to execute. Usage: manage-vms.sh exec <name> [options] -- <cmd...>", file=sys.stderr)
        sys.exit(1)

    data = load_registry()
    name = parsed.name.strip()
    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]
    port = parsed.port or vm.get("ssh_port", 2222)
    os_type = vm.get("os", "generic").lower()
    user = parsed.user or ("admin" if os_type in ["windows", "macos"] else "ubuntu" if os_type == "ubuntu" else "root")
    password = parsed.password or ("admin" if os_type == "windows" else None)

    guest_cmd = " ".join(cmd_args) if len(cmd_args) > 1 else cmd_args[0]

    ssh_base = [
        "ssh",
        "-p", str(port),
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", f"ConnectTimeout={min(parsed.timeout, 15)}",
        "-o", "LogLevel=ERROR",
    ]

    if parsed.key:
        ssh_base.extend(["-i", os.path.abspath(parsed.key)])
    elif password:
        ssh_base.extend(["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"])

    target_dest = f"{user}@127.0.0.1"

    def run_interactive_pty(cmd_list, pwd=None, timeout_sec=60):
        if not pwd or shutil.which("sshpass"):
            if pwd and shutil.which("sshpass"):
                full = ["sshpass", "-p", pwd] + cmd_list
            else:
                full = cmd_list
            return subprocess.run(full).returncode
        try:
            import pty, select
            child_pid, master = pty.fork()
            if child_pid == 0:
                os.execvp(cmd_list[0], cmd_list)
            buf = b""
            password_sent = False
            start_time = time.time()
            child_status = None
            while child_status is None:
                if time.time() - start_time > timeout_sec:
                    os.kill(child_pid, signal.SIGKILL)
                    os.waitpid(child_pid, 0)
                    os.close(master)
                    return 124
                r, _, _ = select.select([master], [], [], 0.1)
                if master in r:
                    try:
                        data = os.read(master, 1024)
                        if not data:
                            break
                        buf += data
                        if not password_sent and (b"password:" in buf.lower() or b"password for" in buf.lower()):
                            os.write(master, (pwd + "\r").encode("utf-8"))
                            password_sent = True
                            buf = b""
                        else:
                            sys.stdout.buffer.write(data)
                            sys.stdout.buffer.flush()
                    except OSError:
                        break
                waited_pid, status = os.waitpid(child_pid, os.WNOHANG)
                if waited_pid == child_pid:
                    child_status = status
            os.close(master)
            if child_status is None:
                _, child_status = os.waitpid(child_pid, 0)
            return os.waitstatus_to_exitcode(child_status)
        except Exception:
            return subprocess.run(cmd_list).returncode

    try:
        rc = run_interactive_pty(ssh_base + [target_dest, guest_cmd], password, parsed.timeout)
        sys.exit(rc)
    except FileNotFoundError:
        print("[ERROR] 'ssh' binary not found.", file=sys.stderr)
        sys.exit(1)

elif action in ["copy-to", "copy-from"]:
    parser = argparse.ArgumentParser(prog=f"manage-vms {action}")
    parser.add_argument("name")
    parser.add_argument("src")
    parser.add_argument("dest")
    parser.add_argument("--user", default=None)
    parser.add_argument("--password", default=None)
    parser.add_argument("--key", default=None)
    parser.add_argument("--port", type=int, default=None)
    parsed = parser.parse_args(args)

    data = load_registry()
    name = parsed.name.strip()
    if name not in data["vms"]:
        print(f"[ERROR] VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    vm = data["vms"][name]
    port = parsed.port or vm.get("ssh_port", 2222)
    os_type = vm.get("os", "generic").lower()
    user = parsed.user or ("admin" if os_type in ["windows", "macos"] else "ubuntu" if os_type == "ubuntu" else "root")
    password = parsed.password or ("admin" if os_type == "windows" else None)

    scp_base = [
        "scp",
        "-P", str(port),
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-r"
    ]

    if parsed.key:
        scp_base.extend(["-i", os.path.abspath(parsed.key)])
    elif password:
        scp_base.extend(["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"])

    if action == "copy-to":
        src_path = os.path.abspath(parsed.src)
        dest_target = f"{user}@127.0.0.1:{parsed.dest}"
        transfer_cmd = scp_base + [src_path, dest_target]
    else:
        src_target = f"{user}@127.0.0.1:{parsed.src}"
        dest_path = os.path.abspath(parsed.dest)
        transfer_cmd = scp_base + [src_target, dest_path]

    def run_interactive_pty(cmd_list, pwd=None, timeout_sec=120):
        if not pwd or shutil.which("sshpass"):
            if pwd and shutil.which("sshpass"):
                full = ["sshpass", "-p", pwd] + cmd_list
            else:
                full = cmd_list
            return subprocess.run(full).returncode
        try:
            import pty, select
            child_pid, master = pty.fork()
            if child_pid == 0:
                os.execvp(cmd_list[0], cmd_list)
            buf = b""
            password_sent = False
            start_time = time.time()
            child_status = None
            while child_status is None:
                if time.time() - start_time > timeout_sec:
                    os.kill(child_pid, signal.SIGKILL)
                    os.waitpid(child_pid, 0)
                    os.close(master)
                    return 124
                r, _, _ = select.select([master], [], [], 0.1)
                if master in r:
                    try:
                        data = os.read(master, 1024)
                        if not data:
                            break
                        buf += data
                        if not password_sent and (b"password:" in buf.lower() or b"password for" in buf.lower()):
                            os.write(master, (pwd + "\r").encode("utf-8"))
                            password_sent = True
                            buf = b""
                        else:
                            sys.stdout.buffer.write(data)
                            sys.stdout.buffer.flush()
                    except OSError:
                        break
                waited_pid, status = os.waitpid(child_pid, os.WNOHANG)
                if waited_pid == child_pid:
                    child_status = status
            os.close(master)
            if child_status is None:
                _, child_status = os.waitpid(child_pid, 0)
            return os.waitstatus_to_exitcode(child_status)
        except Exception:
            return subprocess.run(cmd_list).returncode

    try:
        rc = run_interactive_pty(transfer_cmd, password, 120)
        sys.exit(rc)
    except FileNotFoundError:
        print("[ERROR] 'scp' binary not found.", file=sys.stderr)
        sys.exit(1)

elif action == "run-ephemeral":
    split_idx = -1
    for i, a in enumerate(args):
        if a == "--":
            split_idx = i
            break

    if split_idx != -1:
        flag_args = args[:split_idx]
        cmd_args = args[split_idx + 1:]
    else:
        flag_args = args[:1]
        cmd_args = args[1:]

    parser = argparse.ArgumentParser(prog="manage-vms run-ephemeral")
    parser.add_argument("name")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--user", default=None)
    parser.add_argument("--password", default=None)
    parser.add_argument("--key", default=None)
    parsed = parser.parse_args(flag_args)

    if not cmd_args:
        print("[ERROR] No command specified. Usage: manage-vms.sh run-ephemeral <base-name> [options] -- <cmd...>", file=sys.stderr)
        sys.exit(1)

    name = parsed.name.strip()
    data = load_registry()
    if name not in data["vms"]:
        print(f"[ERROR] Base VM '{name}' not found in registry.", file=sys.stderr)
        sys.exit(2)

    script_self = sys.argv[0] if sys.argv[0] != "-" else "/bin/bash"

    print(f"[INFO] Starting ephemeral snapshot instance of '{name}'...")
    # Start VM in daemon snapshot mode
    subprocess.run([sys.executable, "-", config_dir, registry_path, images_dir, run_dir, "start", name, "--daemon", "--snapshot"], input=open(__file__).read() if __file__ != "<stdin>" else "", text=True)

    # Wait for SSH
    print(f"[INFO] Waiting for guest readiness...")
    wait_res = subprocess.run([sys.executable, "-", config_dir, registry_path, images_dir, run_dir, "wait-ready", name, "--timeout", str(parsed.timeout)])
    if wait_res.returncode != 0:
        print(f"[ERROR] Ephemeral VM failed to become ready.", file=sys.stderr)
        # Cleanup
        subprocess.run([sys.executable, "-", config_dir, registry_path, images_dir, run_dir, "stop", name, "--force"])
        sys.exit(1)

    # Run command
    print(f"[INFO] Executing guest command in ephemeral instance...")
    exec_args = [sys.executable, "-", config_dir, registry_path, images_dir, run_dir, "exec", name]
    if parsed.user: exec_args.extend(["--user", parsed.user])
    if parsed.password: exec_args.extend(["--password", parsed.password])
    if parsed.key: exec_args.extend(["--key", parsed.key])
    exec_args.append("--")
    exec_args.extend(cmd_args)

    cmd_res = subprocess.run(exec_args)
    cmd_code = cmd_res.returncode

    # Stop VM
    print(f"[INFO] Tearing down ephemeral instance (all writes discarded)...")
    subprocess.run([sys.executable, "-", config_dir, registry_path, images_dir, run_dir, "stop", name, "--force"])
    sys.exit(cmd_code)

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
  start|run|boot)
    run_py_gateway "start" "$@"
    ;;
  send-key|key)
    run_py_gateway "send-key" "$@"
    ;;
  type-text|type)
    run_py_gateway "type-text" "$@"
    ;;
  screenshot|capture)
    run_py_gateway "screenshot" "$@"
    ;;
  stop|halt|kill|shutdown)
    run_py_gateway "stop" "$@"
    ;;
  status)
    run_py_gateway "status" "$@"
    ;;
  wait-ready|wait-ssh|wait)
    run_py_gateway "wait-ready" "$@"
    ;;
  exec|ssh)
    run_py_gateway "exec" "$@"
    ;;
  copy-to|upload|push)
    run_py_gateway "copy-to" "$@"
    ;;
  copy-from|download|pull)
    run_py_gateway "copy-from" "$@"
    ;;
  run-ephemeral|ephemeral)
    run_py_gateway "run-ephemeral" "$@"
    ;;
  snapshot|snap)
    run_py_gateway "snapshot" "$@"
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
