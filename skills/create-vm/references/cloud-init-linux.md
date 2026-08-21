# Linux Cloud-Init Instant VM Provisioning Reference

This reference covers Linux virtual machine instantiation using Ubuntu and Debian cloud images, cloud-init, and copy-on-write linked overlays. Alpine media is not yet implemented by the bundled fetcher or creator.

## 1. Cloud Image Sources

| Distribution | Source Format | Target Extension | Default Cloud User |
| :--- | :--- | :--- | :--- |
| **Ubuntu 24.04 (Noble)** | Raw / QCow2 image | `.img` | `ubuntu` |
| **Debian 12 (Bookworm)** | Generic cloud QCow2 | `.qcow2` | `debian` / `root` |

## 2. Instant Provisioning Workflow

Instead of running an interactive installer, `create-linux-vm.sh` downloads the upstream image once, generates per-VM NoCloud seed media and SSH identity, and registers a disposable thin overlay.

When `manage-vms.sh create` is called with `--backing-file`:
```bash
./skills/create-vm/scripts/create-linux-vm.sh my-ubuntu \
  --os ubuntu --size 20G --memory 2G --cpus 2 \
  --purpose "Run the Linux smoke suite" \
  --release-when "Logs and exit status are saved outside the guest"
```

- The upstream cloud image is reusable cached media, not a customized template.
- The writable overlay, seed media, and generated SSH key are VM-owned and removed by `manage-vms.sh release`.
- Actual boot and provisioning time depends on host, image, networking, and requested packages; readiness is proven by SSH rather than a fixed delay.
