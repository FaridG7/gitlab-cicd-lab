# Terraform — libvirt/KVM VM Provisioning

Provisions the Ubuntu 24.04 VM that the rest of the pipeline deploys to. Uses the community [`dmacvicar/libvirt`](https://registry.terraform.io/providers/dmacvicar/libvirt) provider to manage the VM, its disks, and a cloud-init disk on the local libvirt daemon — no cloud account required.

> Part of the [gitlab-cicd-lab](../README.md) project. This is the **first** stage of the pipeline: it creates the target server that GitLab CI later deploys to.

---

## What It Creates

| Resource                       | Purpose                                                          |
| ------------------------------ | ---------------------------------------------------------------- |
| `libvirt_volume.base`          | Backing qcow2 from the Ubuntu cloud image                        |
| `libvirt_volume.root_disk`     | The VM's 20 GB root disk, backed by `base`                       |
| `libvirt_cloudinit_disk.init`  | cloud-init ISO: hostname, SSH key, qemu-guest-agent, static IP   |
| `libvirt_domain.webserver-vm`  | The VM itself: 4 vCPU, 4 GiB RAM, KVM, virtio NIC + disk         |

The VM boots, cloud-init injects the authorized key and configures `eth0` with the static IP from `terraform.tfvars`, and the qemu-guest-agent lets Terraform report the assigned IP.

## Files

```
terraform/
├── main.tf               # Active config: VM, volumes, cloud-init, network
├── user-data.tftpl       # cloud-init user-data (user, SSH key, packages)
├── meta-data.tftpl       # cloud-init meta-data (instance-id, hostname)
├── network-config.tftpl  # Static IP / gateway / DNS for eth0
├── terraform.tfvars      # YOUR values (gitignored)
├── iso/                  # Earlier single-VM variant (reference only)
└── .terraform.lock.hcl   # Provider lock
```

> `terraform/iso/` is an earlier iteration that used a single `vm_hostname` variable and a different cloud-init layout. **`main.tf` at the top level is the active configuration.** The `iso/` copy is kept for reference.

## Prerequisites

On the host:

- **libvirt + KVM** running, with the `default` network up (`virsh net-start default`).
- Your user able to talk to `qemu:///system` (typically membership in the `libvirt` group).
- **Terraform** `~> 1.15`.
- The **Ubuntu 24.04 cloud image**, downloaded once:

  ```bash
  mkdir -p iso
  wget -O iso/noble-server-cloudimg-amd64.img \
    https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
  ```

  (`main.tf` points at this local file so applies work fully offline; the commented `url =` line shows the upstream source.)

- An **SSH keypair** whose public half will be authorized inside the VM (default `~/.ssh/id_rsa.pub`).

## Getting Started

**1. Create your variables file**

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — most importantly the `ip_address`, `mac_address`, and `ssh_public_key_path`:

```hcl
vm = {
  hostname    = "ubuntu-vm"
  mac_address = "52:54:00:5b:62:06"   # must match network-config.tftpl's NIC
  ip_address  = "192.168.122.100"      # within the libvirt default network
  gateway     = "192.168.122.1"
  dns         = "192.168.122.1"
}
ssh_public_key_path = "~/.ssh/id_rsa.pub"
```

**2. Init and apply**

```bash
terraform init
terraform apply
```

**3. Verify**

```bash
ssh ubuntu@192.168.122.100
```

cloud-init creates the `ubuntu` user with passwordless sudo and your SSH key; password and root login are disabled.

## Variables

| Name                   | Description                          | Type        |
| ---------------------- | ------------------------------------ | ----------- |
| `vm`                   | Map of `hostname`, `mac_address`, `ip_address`, `gateway`, `dns` | `map(string)` |
| `ssh_public_key_path`  | Path to the public key to authorize  | `string`    |

## Outputs

| Name    | Description                                   |
| ------- | --------------------------------------------- |
| `vm_ip` | IP address reported by the qemu-guest-agent   |

> If `terraform apply` seems to hang waiting for the IP, confirm the guest agent is running inside the VM (cloud-init installs and starts it) — see the [Troubleshooting](../README.md#troubleshooting) section of the root README.

## Teardown

```bash
terraform destroy
```

This removes the VM and all volumes it created. The downloaded cloud image under `iso/` and the libvirt `default` network are left untouched.
