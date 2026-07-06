from fastapi import APIRouter, Request

from app.common.responses import success_response
from app.connections.models import PROVIDER_OBJECT_TYPES

router = APIRouter(prefix="/v1/providers", tags=["providers"])

# One source of truth for the OpenFGA backend object type per provider lives in
# app/connections/models.py::PROVIDER_OBJECT_TYPES. Each provider entry below
# pulls its `fga_object_type` from that registry so they cannot drift.
PROVIDERS = [
    {
        "id": "aws",
        "name": "Amazon Web Services",
        "driver": "ec2",
        "fga_object_type": PROVIDER_OBJECT_TYPES["aws"],
        "supported_operations": [
            "list_nodes", "create_node", "destroy_node", "update_node",
            "start_node", "stop_node", "reboot_node", "resize_node",
            "list_images", "create_image", "delete_image",
            "list_sizes", "list_locations",
            "list_volumes", "create_volume", "destroy_volume", "attach_volume", "detach_volume",
            "list_snapshots", "create_snapshot", "destroy_snapshot",
            "list_key_pairs", "create_key_pair", "delete_key_pair",
            "list_networks", "create_network", "destroy_network",
            "list_subnets", "create_subnet", "update_subnet", "destroy_subnet",
        ],
    },
    {
        "id": "nutanix",
        "name": "Nutanix Prism Central",
        "driver": "nutanix",
        "fga_object_type": PROVIDER_OBJECT_TYPES["nutanix"],
        "supported_operations": [
            "list_nodes", "create_node", "destroy_node", "update_node",
            "start_node", "stop_node", "reboot_node",
            "list_images", "create_image", "delete_image",
            "list_sizes", "list_locations", "list_storage_containers",
            "list_volumes", "create_volume", "destroy_volume", "attach_volume", "detach_volume",
            "list_snapshots", "create_snapshot", "destroy_snapshot",
            "list_networks", "create_network", "update_network", "destroy_network",
            "list_subnets", "create_subnet", "update_subnet", "destroy_subnet",
            "list_security_groups", "create_security_group", "destroy_security_group",
            "list_load_balancers", "create_load_balancer", "destroy_load_balancer",
        ],
    },
]


@router.get("")
def list_providers(request: Request):
    return success_response(PROVIDERS, request)
