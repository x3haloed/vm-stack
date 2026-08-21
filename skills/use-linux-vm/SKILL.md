---
name: use-linux-vm
description: Use when a task needs testing, building, reproducing, or running on Linux, including implicit requests such as “test this on Linux,” compatibility work, supported-distribution checks, or isolation in a Linux guest, even when the user does not mention vm-stack.
---

# Use a Linux VM

Turn Linux requirements in the current project into a purpose-bound local VM, use it to obtain the requested result, and release it when its purpose is satisfied.

Use [../create-vm/scripts/create-linux-vm.sh](../create-vm/scripts/create-linux-vm.sh) for Ubuntu or Debian creation and route every lifecycle operation through [../manage-vms/scripts/manage-vms.sh](../manage-vms/scripts/manage-vms.sh).

## Resolve the guest from evidence

Inspect the project before asking the user. Treat CI matrices, support tables, lockfiles, container bases, deployment manifests, and issue reproduction details as stronger evidence than generic defaults.

- Test every Linux flavor/version explicitly claimed by the project when compatibility across them is the purpose.
- For a generic Linux smoke test with no project evidence, use one host-native Ubuntu LTS server guest.
- Ask the user when multiple plausible choices would test materially different behavior and the project does not resolve them.
- Use a server image unless the target workflow requires a window manager, browser rendering, desktop integration, GPU/display behavior, or the user requests a graphical environment. Ask when that distinction is consequential but unclear.
- Match the host architecture for fast hardware acceleration unless cross-architecture behavior is itself under test.

The bundled automated path currently supports Ubuntu 24.04 and Debian 12. If evidence requires another distribution or version, do not silently substitute one of these; obtain matching media or ask the user how broadly to interpret the request.

## Size from the workload

Estimate resources from the actual build/test path and project guidance. Start with the smallest credible allocation and increase it when evidence shows pressure.

- Lightweight CLI, scripting, or package checks: 2 vCPUs, 2 GiB RAM, 20 GiB disk.
- Compilers, browser tests, databases, or parallel suites: use project/CI settings when available; otherwise begin around 4 vCPUs, 4-8 GiB RAM, and 30-40 GiB disk.
- Desktop environments: add capacity for the desktop and workload rather than applying a fixed “Linux VM” size.

Consider host capacity before allocating. A VM that starves the host is not a faithful test environment.

## Decide what persists

Separate three resources that have different retention economics:

1. The downloaded upstream cloud image is cached installation media and may remain for future creation.
2. The writable task VM is disposable by default. Give it a concrete purpose and an observable release condition.
3. A customized, checkpointed, or sealed reusable template is durable state. Create or retain one only when the user requests it, or when measured repeated setup cost and a likely repeated workload justify its disk and maintenance cost. One speculative future use is not evidence.

Prefer a fresh cloud-image overlay when setup is cheap, environmental freshness matters, or disk space is the stronger constraint. Prefer a reusable customized template only after successful provisioning is verified and reuse is genuinely expected. Record what makes it reusable and what would invalidate it.

## Execute and close the loop

Before creation, state the selected distribution/version, architecture, GUI choice, resource allocation, purpose, release condition, and retention decision. Then:

```bash
./skills/create-vm/scripts/create-linux-vm.sh linux-check \
  --os ubuntu --memory 2G --cpus 2 --size 20G \
  --purpose "Run the project's documented Linux test command" \
  --release-when "Test output and environment details are saved outside the guest"
```

Copy only the needed source or artifacts into the guest, run the task, and capture at least the distribution release, architecture, invoked command, exit status, and relevant logs outside the VM. If the result exposes a new unresolved question, keep the disposable guest only while that question still depends on its state.

Once the release condition is true:

```bash
./skills/manage-vms/scripts/manage-vms.sh release linux-check
```

Report what was tested, the evidence captured, and whether the VM was released or retained with its continuing reason.
