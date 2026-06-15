terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
  }
  required_version = "~> 1.15.6"
}

variable "vm" {
  description = "Data used for the vm initialization"
  type        = map(string)
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
}

resource "libvirt_cloudinit_disk" "init" {
  name = "vm-init"
  user_data = templatefile("${path.module}/user-data.tftpl", {
    hostname       = var.vm.hostname
    ssh_public_key = trimspace(file(var.ssh_public_key_path))
  })

  meta_data = templatefile("${path.module}/meta-data.tftpl", {
    hostname    = var.vm.hostname
    instance_id = var.vm.hostname
  })

  network_config = templatefile("${path.module}/network-config.tftpl", {
    mac_address = var.vm.mac_address
    ip_address  = var.vm.ip_address
    gateway     = var.vm.gateway
    dns         = var.vm.dns
  })
}

resource "libvirt_volume" "cloudinit" {
  name = "vm-cloudinit"
  pool = "default"
  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.init.path
    }
  }
}

resource "libvirt_volume" "base" {
  name = "ubuntu-24.04.qcow2"
  pool = "default"

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      # url = "https://cloud-images.ubuntu.com/noble/20260518/noble-server-cloudimg-amd64.img"
      url = "./iso/noble-server-cloudimg-amd64.img"
    }
  }
}

resource "libvirt_volume" "root_disk" {
  name     = "${var.vm.hostname}-root.qcow2"
  pool     = "default"
  capacity = 21474836480 # 20 GB in bytes
  target = {
    format = {
      type = "qcow2"
    }
  }
  backing_store = {
    path = libvirt_volume.base.path
    format = {
      type = "qcow2"
    }
  }
}
# Basic VM configuration
resource "libvirt_domain" "terraform-lab" {
  name        = "terraform-lab"
  memory      = 4096
  memory_unit = "MiB"
  vcpu        = 4
  type        = "kvm"
  running     = true

  os = {
    type = "hvm"
  }

  devices = {
    disks = [
      {
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = libvirt_volume.root_disk.pool
            volume = libvirt_volume.root_disk.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        device = "cdrom"
        driver = {
          name = "qemu"
          type = "raw"
        }
        target = { dev = "sda", bus = "sata" }
        source = {
          volume = {
            pool   = libvirt_volume.cloudinit.pool
            volume = libvirt_volume.cloudinit.name
          }
        }
      }
    ]
    interfaces = [
      {
        mac = { address = var.vm.mac_address }
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = "default"
          }
        }
        wait_for_ip = {
          source = "agent"
        }
      }
    ]
    consoles = [
      {
        type = "pty"
        target = {
          type = "serial"
          port = 0
        }
      }
    ]
    channels = [
      {
        source = {
          unix = {
            mode = "bind"
          }
        }
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      }
    ]
  }
}
