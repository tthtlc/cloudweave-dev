
Nutanix

   def __init__(
    def list_nodes(self, **kwargs):
    def list_images(self, location=None, **kwargs):
    def get_image(self, image_id):
    def create_image(self, node, name, description=None, **kwargs):
    def ex_create_image_from_url(self, name, url, description=None, **kwargs):
    def delete_image(self, node_image, **kwargs):
    def list_sizes(self, location=None):
    def list_locations(self):
    def create_node(
    def destroy_node(self, node, **kwargs):
    def reboot_node(self, node, **kwargs):
    def start_node(self, node, **kwargs):
    def stop_node(self, node, **kwargs):
    def ex_get_node(self, node_id):
    def ex_update_node(self, node_id, **kwargs):
    def ex_get_task(self, task_id):
    def ex_list_clusters(self, **kwargs):
    def ex_list_subnets(self, **kwargs):
    def ex_get_subnet(self, subnet_id):
    def ex_create_subnet(
    def ex_update_subnet(self, subnet_id, **kwargs):
    def ex_delete_subnet(self, subnet_id, **kwargs):
    def ex_list_vpcs(self, **kwargs):
    def ex_get_vpc(self, vpc_id):
    def ex_create_vpc( 
    def ex_update_vpc(self, vpc_id, **kwargs):
    def ex_delete_vpc(self, vpc_id, **kwargs):
    def ex_list_storage_containers(self, **kwargs):
    def ex_get_storage_container(self, container_id):
    def ex_list_storage_containers_vmm(self, **kwargs):
    def ex_get_storage_container_vmm(self, container_id):
    def ex_list_templates(self, **kwargs):
    def ex_list_security_groups(self, **kwargs):
    def ex_get_security_group(self, policy_id):
    def ex_create_security_group(
    def ex_delete_security_group(self, policy_id, **kwargs):
    def ex_list_load_balancers(self, **kwargs):
    def ex_get_load_balancer(self, floating_ip_id):
    def ex_create_load_balancer(
    def ex_delete_load_balancer(self, floating_ip_id, **kwargs):
    def list_volumes(self, **kwargs):
    def create_volume(self, size, name, location=None, snapshot=None, **kwargs):
    def destroy_volume(self, volume, **kwargs):
    def attach_volume(self, node, volume, device=None, **kwargs):
    def detach_volume(self, volume, **kwargs):
    def create_volume_snapshot(self, volume, name=None, **kwargs):
    def list_volume_snapshots(self, volume, **kwargs):
    def destroy_volume_snapshot(self, snapshot, **kwargs):
    def ex_get_volume(self, volume_id):
    def ex_get_volume_snapshot(self, recovery_point_id, volume=None):
    def ex_list_volume_vm_attachments(self, volume_group_id, **kwargs):
    def _execute_async_mutation(self, method, path, data=None, headers=None, **kwargs):
    def _vm_power_action(self, node_id, action, **kwargs):
    def _get_vm_etag(self, node_id):
    def _get_volume_group_etag(self, volume_group_id):
    def _get_recovery_point_etag(self, recovery_point_id):
                                                                                                                                                                                                                                                                                                    13,5          Top


