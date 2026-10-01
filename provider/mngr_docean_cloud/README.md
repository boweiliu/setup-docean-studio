# mngr docean_cloud provider

A custom `mngr` provider backend that runs agents on nested-KVM virtual machines
managed by **libvirt** on a single host (e.g. a DigitalOcean droplet with nested
virtualization enabled).

It is built on the shared `mngr_vps` substrate: each agent gets its own VM
(1:1 host:VM). By default the agent runs in a Docker container *inside* the VM
(`isolation=CONTAINER`, the standard VPS behavior), reusing all of the shared
container realizer / provisioning / discovery machinery.

## How it works

- `create_host` asks the `docean_cloud` `VpsClient` to provision a VM:
  - a copy-on-write qcow2 overlay on top of a cloud-init-enabled base image
    (Ubuntu cloud image by default),
  - a NoCloud seed ISO carrying the cloud-init `user-data` mngr generates
    (installs Docker, injects the SSH host + provider keys, ...),
  - a libvirt domain on the `default` NAT network (`192.168.122.0/24`).
- mngr waits for the VM to boot, obtains its DHCP lease IP, SSHes in as
  `root@<vm-ip>:22` with the provider keypair, waits for cloud-init to finish,
  then runs the agent container exactly like any other VPS provider.
- `destroy` tears down the libvirt domain, its disk overlay and seed ISO.

## Configuration

```toml
[providers.docean_cloud]
backend = "docean_cloud"
# base cloud image (qcow2) to use as the qcow2 backing file
base_image = "/var/lib/libvirt/images/ubuntu-24.04-server-cloudimg-amd64.img"
# default VM size, parsed as "<vcpus>c<ram_gb>g" (e.g. "2c4g")
default_plan = "2c4g"
# directory for per-VM disks, seed ISOs and the instance registry
images_dir = "/var/lib/libvirt/images/docean_cloud"
# libvirt network to attach VMs to (must provide DHCP + outbound NAT)
network = "default"
# gigabytes held back from the in-VM btrfs loop file (see mngr_vps docs)
outer_disk_reserved_gb = 5
# gigabytes of virtual disk per VM (thin qcow2)
vm_disk_gb = 40
```

No API credentials are required -- the "cloud" is the local libvirt daemon.
