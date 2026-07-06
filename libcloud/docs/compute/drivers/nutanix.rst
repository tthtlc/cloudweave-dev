Nutanix Compute Driver Documentation
====================================

`Nutanix`_ Prism Central driver for Apache Libcloud. It targets the **v4.0 REST API**
for **AHV** workloads: VMs, images, volume groups, and recovery-point snapshots.

.. note::

   Extended guides with architecture notes and copy-paste examples:

   - ``contrib/docker/nutanix/NUTANIX_LIBCLOUD_CONCEPTUAL_GUIDE.md``
   - ``contrib/docker/nutanix/NUTANIX_LIBCLOUD_DEVELOPER_GUIDE.md``

Instantiating a driver
------------------------

Connect to Prism Central with HTTP Basic authentication (username + password).
Default port is ``9440`` and default API version is ``v4.0``.

.. code-block:: python

   from libcloud.compute.providers import get_driver
   from libcloud.compute.types import Provider

   cls = get_driver(Provider.NUTANIX)
   driver = cls(
       key="admin",
       secret="password",
       host="prism-central.example.com",
       port=9440,
       api_version="v4.0",
       verify_ssl_cert=True,
   )

Conceptual overview
-------------------

Libcloud exposes Nutanix through portable compute abstractions:

- **Nodes** → AHV VMs (``vmm`` namespace)
- **NodeImage** → content images (``vmm`` namespace)
- **NodeLocation** → clusters (``clustermgmt`` namespace)
- **StorageVolume** → volume groups (``volumes`` namespace)
- **VolumeSnapshot** → recovery points (``dataprotection`` namespace)

Async mutations return a Prism **task** (HTTP 202). The driver polls
``/api/prism/v4.0/config/tasks/{extId}`` by default (``ex_wait=True``).

See the conceptual guide for namespace layout, ETag handling, OData pagination,
and synthetic size presets.

Quick start — create a VM
-------------------------

.. code-block:: python

   cluster = driver.list_locations()[0]
   size = driver.list_sizes()[0]
   image = driver.list_images()[0]

   node = driver.create_node(
       name="my-vm",
       size=size,
       image=image,
       location=cluster,
       ex_subnet="<subnet-ext-id>",
       ex_storage_container="<storage-container-ext-id>",
   )

Implemented API summary
-----------------------

**Compute:** ``list_nodes``, ``create_node``, ``destroy_node``,
``start_node``, ``stop_node``, ``reboot_node``

**Images:** ``list_images``, ``get_image``, ``create_image``, ``delete_image``,
``ex_create_image_from_url``

**Volumes:** ``list_volumes``, ``create_volume``, ``destroy_volume``,
``attach_volume``, ``detach_volume``

**Snapshots:** ``create_volume_snapshot``, ``list_volume_snapshots``,
``destroy_volume_snapshot``

**Extensions:** ``ex_get_node``, ``ex_get_task``, ``ex_list_clusters``,
``ex_list_subnets``, ``ex_list_storage_containers``, ``ex_get_volume``,
``ex_get_volume_snapshot``, ``ex_list_volume_vm_attachments``

Testing
-------

Unit and integration tests run in Docker:

.. code-block:: bash

   cd contrib/docker/nutanix
   ./run_tests.sh
   NUTANIX_INTEGRATION_TESTS=1 ./run_tests.sh integration

API Docs
--------

.. autoclass:: libcloud.compute.drivers.nutanix.NutanixNodeDriver
    :members:
    :inherited-members:

.. _`Nutanix`: https://www.nutanix.com/
