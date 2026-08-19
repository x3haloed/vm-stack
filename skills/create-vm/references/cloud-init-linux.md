# Linux Cloud-Init Instant VM Provisioning Reference

This reference covers instant Linux virtual machine instantiation using pre-baked cloud images (Ubuntu, Debian, Alpine) with Copy-on-Write linked overlays.

## 1. Cloud Image Sources

| Distribution | Source Format | Target Extension | Default Cloud User |
| :--- | :--- | :--- | :--- |
| **Ubuntu 24.04 (Noble)** | Raw / QCow2 image | `.img` | `ubuntu` |
| **Debian 12 (Bookworm)** | Generic cloud QCow2 | `.qcow2` | `debian` / `root` |
| **Alpine Linux** | Virtual QCow2 | `.qcow2` | `alpine` / `root` |

## 2. Instant Provisioning Workflow

Instead of running an interactive Linux distribution installer, `fetch-media.sh` downloads the upstream cloud image once into `~/.config/vm-stack/media/`.

When `manage-vms.sh create` is called with `--backing-file`:
```bash
# 1. Download base image once
./skills/create-vm/scripts/fetch-media.sh ubuntu

# 2. Create lightweight copy-on-write overlay in seconds
./skills/manage-vms/scripts/manage-vms.sh create my-ubuntu \
  --size 20G \
  --backing-file ~/.config/vm-stack/media/ubuntu-24.04-server-cloudimg-aarch64.img \
  --os ubuntu \
  --arch aarch64
```

- **Creation Time:** < 1 second.
- **Disk Usage:** < 100 KB initial delta disk.
- **Boot Time:** ~5-10 seconds to full SSH login prompt.
