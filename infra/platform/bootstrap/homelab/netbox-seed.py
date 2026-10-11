"""Idempotently seed the evidence-backed Homelab inventory into NetBox.

This file is executed inside the NetBox container by bootstrap-netbox.sh.
It contains no credentials and only records the private-LAN assets documented
in operations/platform/HOMELAB-INVENTORY.md.
"""

from dcim.models import Device, DeviceRole, DeviceType, Interface, Manufacturer, Site
from ipam.models import IPAddress
from virtualization.models import Cluster, ClusterType, VMInterface, VirtualMachine


site, _ = Site.objects.get_or_create(
    slug="homelab",
    defaults={"name": "Homelab", "status": "active"},
)

manufacturer, _ = Manufacturer.objects.get_or_create(
    slug="local",
    defaults={"name": "Local"},
)


def role(name: str, slug: str, color: str = "607d8b") -> DeviceRole:
    item, _ = DeviceRole.objects.get_or_create(
        slug=slug,
        defaults={"name": name, "color": color},
    )
    return item


roles = {
    "hypervisor": role("Hypervisor", "hypervisor", "1565c0"),
    "workstation": role("Workstation", "workstation", "00897b"),
    "registry": role("Container Registry", "container-registry", "6a1b9a"),
    "network": role("Network Device", "network-device", "ef6c00"),
}


def device_type(model: str, slug: str) -> DeviceType:
    item, _ = DeviceType.objects.get_or_create(
        slug=slug,
        defaults={"manufacturer": manufacturer, "model": model, "u_height": 1},
    )
    return item


def add_ip(interface, address: str, description: str) -> IPAddress:
    ip, _ = IPAddress.objects.get_or_create(
        address=address,
        defaults={"status": "active", "description": description},
    )
    if ip.assigned_object_id != interface.pk:
        ip.assigned_object = interface
        ip.save()
    return ip


def add_device(name: str, address: str, model: str, type_slug: str, role_key: str, comments: str):
    item, _ = Device.objects.get_or_create(
        name=name,
        site=site,
        defaults={
            "device_type": device_type(model, type_slug),
            "role": roles[role_key],
            "status": "active",
            "comments": comments,
        },
    )
    interface, _ = Interface.objects.get_or_create(
        device=item,
        name="management",
        defaults={"type": "1000base-t"},
    )
    ip = add_ip(interface, f"{address}/24", f"Management address observed in Homelab inventory")
    if item.primary_ip4_id != ip.pk:
        item.primary_ip4 = ip
        item.save()
    return item


add_device(
    "beelink",
    "192.168.152.10",
    "Proxmox VE 9.1.1 / Intel N150",
    "proxmox-ve-intel-n150",
    "hypervisor",
    "Proxmox member; hosts K3s VM 114. Evidence: HOMELAB-INVENTORY.md.",
)
add_device(
    "proxmox-laptop-asus-vivobooks14",
    "192.168.152.11",
    "Proxmox VE 9.1.1 / AMD Ryzen 5 7535HS",
    "proxmox-ve-ryzen-7535hs",
    "hypervisor",
    "Proxmox cluster member; future capacity candidate. Evidence: HOMELAB-INVENTORY.md.",
)
add_device(
    "bookchaowalit-MS-7D98",
    "192.168.152.150",
    "Ubuntu 26.04 LTS / Intel Core i5-14400F",
    "ubuntu-workstation-i5-14400f",
    "workstation",
    "Standalone operator/development workstation; not a Proxmox or K3s node.",
)
add_device(
    "fedora-workstation",
    "192.168.152.12",
    "Fedora Linux 43 / AMD Ryzen 7 4700U",
    "fedora-workstation-ryzen-4700u",
    "registry",
    "Private container registry host; not a K3s node. Evidence: HOMELAB-INVENTORY.md.",
)
add_device(
    "private-lan-gateway",
    "192.168.152.1",
    "ZTE F6107A",
    "zte-f6107a",
    "network",
    "Private-LAN gateway/router observed during the 2026-08-20 read-only probe.",
)

cluster_type, _ = ClusterType.objects.get_or_create(
    slug="k3s",
    defaults={"name": "K3s", "description": "K3s cluster running on the Homelab private LAN."},
)

cluster, _ = Cluster.objects.get_or_create(
    name="homelab-k3s",
    defaults={
        "type": cluster_type,
        "status": "active",
        "comments": "Single-node non-production K3s cluster; evidence-backed Homelab inventory.",
    },
)
vm, _ = VirtualMachine.objects.get_or_create(
    name="solo-k3s-server-01",
    cluster=cluster,
    defaults={
        "status": "active",
        "vcpus": 2,
        "memory": 4096,
        "disk": 40,
        "comments": "VM 114 on Proxmox beelink; K3s control-plane and worker; synthetic/demo workloads only.",
    },
)
vm_interface, _ = VMInterface.objects.get_or_create(
    virtual_machine=vm,
    name="management",
)
vm_ip = add_ip(vm_interface, "192.168.152.114/24", "K3s management address observed in Homelab inventory")
if vm.primary_ip4_id != vm_ip.pk:
    vm.primary_ip4 = vm_ip
    vm.save()

print(
    "NetBox Homelab seed complete: "
    f"site={site.name}, devices={Device.objects.filter(site=site).count()}, "
    f"virtual_machines={VirtualMachine.objects.filter(cluster=cluster).count()}, "
    f"ip_addresses={IPAddress.objects.filter(address__startswith='192.168.152.').count()}"
)
