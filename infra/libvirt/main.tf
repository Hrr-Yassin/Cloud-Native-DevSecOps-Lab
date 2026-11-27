variable "cloud_image" {
  description = "Absolute path to the locally verified amd64 Ubuntu cloud image."
  type        = string

  validation {
    condition     = startswith(var.cloud_image, "/") && fileexists(var.cloud_image)
    error_message = "Provide an absolute path to an existing cloud image."
  }
}

variable "cloud_image_sha256" {
  description = "Expected SHA-256 of the original cloud image."
  type        = string

  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.cloud_image_sha256))
    error_message = "Provide a lowercase SHA-256 checksum."
  }
}

variable "ssh_public_key" {
  description = "Dedicated administrator SSH public key."
  type        = string

  validation {
    condition     = can(regex("^ssh-ed25519 [a-zA-Z0-9+/=]+$", trimspace(var.ssh_public_key)))
    error_message = "Provide an OpenSSH Ed25519 public key with its comment removed."
  }
}

variable "guest_network" {
  description = "An unused local IPv4 /24 within 172.16.0.0/12."
  type        = string
  default     = "172.30.88.0/24"

  validation {
    condition = can(cidrnetmask(var.guest_network)) && can(
      regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]+\\.0/24$", var.guest_network)
    )
    error_message = "Select an unused /24 within 172.16.0.0/12."
  }
}

locals {
  name = "devsecops-lab"
}

resource "libvirt_network" "lab" {
  name      = local.name
  mode      = "nat"
  bridge    = "virbr-dslab"
  addresses = [var.guest_network]
  autostart = true

  dhcp {
    enabled = true
  }
}

resource "libvirt_pool" "lab" {
  name = local.name
  type = "dir"

  target {
    path = "/var/lib/libvirt/images/devsecops-lab"
  }
}

resource "libvirt_volume" "base" {
  name   = "noble-base.qcow2"
  pool   = libvirt_pool.lab.name
  source = var.cloud_image
  format = "qcow2"

  lifecycle {
    precondition {
      condition     = filesha256(var.cloud_image) == var.cloud_image_sha256
      error_message = "The cloud image checksum differs from the pinned value."
    }
  }
}

resource "libvirt_volume" "root" {
  name           = "lab-root.qcow2"
  pool           = libvirt_pool.lab.name
  base_volume_id = libvirt_volume.base.id
  format         = "qcow2"
  size           = 24 * 1024 * 1024 * 1024
}

resource "libvirt_cloudinit_disk" "lab" {
  name = "lab-seed.iso"
  pool = libvirt_pool.lab.name
  user_data = join("\n", ["#cloud-config", yamlencode({
    hostname         = local.name
    manage_etc_hosts = true
    ssh_pwauth       = false
    disable_root     = true
    growpart         = { mode = "auto", devices = ["/"] }
    resize_rootfs    = true
    users = [{
      name                = "labops"
      shell               = "/bin/bash"
      lock_passwd         = true
      sudo                = "ALL=(ALL) NOPASSWD:ALL"
      ssh_authorized_keys = [trimspace(var.ssh_public_key)]
    }]
    write_files = [{
      path        = "/etc/devsecops-lab-instance"
      content     = "devsecops-lab"
      owner       = "root:root"
      permissions = "0444"
    }]
  })])
  meta_data = yamlencode({ instance-id = local.name, local-hostname = local.name })
}

resource "libvirt_domain" "lab" {
  name        = local.name
  description = "Dedicated single-node Cloud-Native DevSecOps laboratory"
  memory      = 8192
  vcpu        = 4
  cloudinit   = libvirt_cloudinit_disk.lab.id
  autostart   = false

  cpu {
    mode = "host-model"
  }

  disk {
    volume_id = libvirt_volume.root.id
  }

  network_interface {
    network_id     = libvirt_network.lab.id
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}

output "guest_ip" {
  description = "Dedicated libvirt guest lease address."
  value       = libvirt_domain.lab.network_interface[0].addresses[0]
}

output "guest_network" {
  description = "Dedicated lab network CIDR, kept in the private local state."
  value       = var.guest_network
}
