'use strict';

const https = require('https');
const fs = require('fs');
const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { createProxyMiddleware } = require('http-proxy-middleware');

// ─── Constants ───────────────────────────────────────────────────────────────
const PORT = 9440;
const PRISM_URL = process.env.PRISM_URL || 'http://prism:4010';
// API version this emulator front-ends. Defaults to v4.0, which preserves the
// legacy path variants below. For v4.1/v4.2/v4.3 the Nutanix paths collapse to
// a single /api/{ns}/v4.x/... form, and AHV VMs live under
// /api/vmm/v4.x/ahv/config/vms (see vmListPaths below).
const API_VERSION = process.env.API_VERSION || 'v4.0';
const API_VERSIONS = API_VERSION === 'v4.0'
  ? ['v4.0.a1', 'v4.0', 'v4.0/ahv']
  : [API_VERSION];
const TASK_TRANSITION_MS = 200;

// ─── Helpers: camelCase ↔ snake_case ────────────────────────────────────────
function toSnakeCase(str) {
  return str.replace(/[A-Z]/g, (m) => '_' + m.toLowerCase());
}

function toCamelCase(str) {
  return str.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
}

// Deep convert object keys
function deepConvert(obj, converter) {
  if (obj === null || obj === undefined) return obj;
  if (Array.isArray(obj)) return obj.map((v) => deepConvert(v, converter));
  if (typeof obj === 'object' && !(obj instanceof Date) && !Buffer.isBuffer(obj)) {
    const out = {};
    for (const [k, v] of Object.entries(obj)) {
      out[converter(k)] = deepConvert(v, converter);
    }
    return out;
  }
  return obj;
}

// ─── In-memory state ─────────────────────────────────────────────────────────
const vmStore = new Map();
const taskStore = new Map();
const volumeGroupStore = new Map();
const recoveryPointStore = new Map();
const vpcStore = new Map();
const fipStore = new Map();    // floating IPs
const nspStore = new Map();    // network security policies

// ─── Seed reference data ─────────────────────────────────────────────────────
const SEED_CLUSTER_ID = '00000000-0000-0000-0000-000000000001';
const SEED_SUBNET_ID = '00000000-0000-0000-0000-000000000002';
const SEED_IMAGE_ID = '00000000-0000-0000-0000-000000000003';
const SEED_STORAGE_CONTAINER_ID = '00000000-0000-0000-0000-000000000005';

const clusters = new Map([
  [SEED_CLUSTER_ID, { ext_id: SEED_CLUSTER_ID, name: 'emulator-cluster', cluster_type: 'AHV' }],
]);

const subnets = new Map([
  [SEED_SUBNET_ID, {
    ext_id: SEED_SUBNET_ID,
    name: 'emulator-primary-subnet',
    network_ip: '10.0.0.0',
    network_prefix: 24,
    gateway_ip: '10.0.0.1',
    subnet_type: 'VLAN',
    cluster: { ext_id: SEED_CLUSTER_ID },
    vlan_id: 100,
  }],
]);

const images = new Map([
  [SEED_IMAGE_ID, {
    ext_id: SEED_IMAGE_ID,
    name: 'emulator-ubuntu-2204',
    image_type: 'DISK_IMAGE',
    size_bytes: 8589934592,
  }],
  ['00000000-0000-0000-0000-000000000004', {
    ext_id: '00000000-0000-0000-0000-000000000004',
    name: 'emulator-centos-9',
    image_type: 'DISK_IMAGE',
    size_bytes: 10737418240,
  }],
]);

const storageContainers = new Map([
  [SEED_STORAGE_CONTAINER_ID, {
    ext_id: SEED_STORAGE_CONTAINER_ID,
    name: 'emulator-default-container',
    cluster: { ext_id: SEED_CLUSTER_ID },
    container_type: 'NFS',
  }],
]);

// ─── Helpers ─────────────────────────────────────────────────────────────────
function nowISO() {
  return new Date().toISOString();
}

function makeTask(operationType, entitiesAffected = [], options = {}) {
  const { completionDetails = [] } = options;
  const extId = uuidv4();
  const task = {
    ext_id: extId,
    operation_type: operationType,
    status: 'QUEUED',
    progress_percent: 0,
    entities_affected: entitiesAffected,
    completion_details: completionDetails,
    error_messages: [],
    created_timestamp: nowISO(),
    last_updated_timestamp: nowISO(),
    completion_timestamp: null,
  };
  taskStore.set(extId, task);

  setTimeout(() => {
    const t = taskStore.get(extId);
    if (t) { t.status = 'RUNNING'; t.progress_percent = 50; t.last_updated_timestamp = nowISO(); }
  }, TASK_TRANSITION_MS);

  setTimeout(() => {
    const t = taskStore.get(extId);
    if (t) {
      t.status = 'SUCCEEDED';
      t.progress_percent = 100;
      t.last_updated_timestamp = nowISO();
      t.completion_timestamp = nowISO();
      if (completionDetails.length) {
        t.completion_details = completionDetails;
      }
    }
  }, TASK_TRANSITION_MS * 2);

  return task;
}

function randomIP() {
  return `10.0.0.${Math.floor(Math.random() * 200) + 10}`;
}

function randomMAC() {
  return '02:00:' + Array.from({ length: 4 }, () =>
    Math.floor(Math.random() * 256).toString(16).padStart(2, '0')
  ).join(':');
}

// Build a full VM resource from the provider's camelCase create body.
// Accepts both snake_case and camelCase.
function buildVmFromCreate(snakeBody, camelBody) {
  const b = { ...snakeBody, ...camelBody }; // merge both formats
  const extId = uuidv4();

  const nics = (b.nics || []).map((n) => {
    // v4.3 renames network_info -> nic_network_info; accept both.
    const ni = n.network_info || n.nic_network_info || {};
    return {
      ext_id: n.ext_id || uuidv4(),
      backing_info: {
        is_connected: n.backing_info?.is_connected ?? false,
        mac_address: n.backing_info?.mac_address || randomMAC(),
        model: n.backing_info?.model || 'VIRTIO',
        num_queues: n.backing_info?.num_queues ?? 1,
      },
      network_info: {
        nic_type: ni.nic_type || 'NORMAL_NIC',
        should_allow_unknown_macs: ni.should_allow_unknown_macs ?? true,
        subnet: {
          ext_id: ni.subnet?.ext_id || SEED_SUBNET_ID,
        },
      },
    };
  });

  const disks = (b.disks || []).map((d) => {
    const bi = d.backing_info || {};
    // v4 disk backing is flat (VmDisk fields directly on backingInfo);
    // accept the legacy vm_disk wrapper as a fallback for older clients.
    const legacy = bi.vm_disk || {};
    const dataSource = bi.data_source || legacy.data_source;
    return {
      ext_id: d.ext_id || uuidv4(),
      disk_address: {
        bus_type: d.disk_address?.bus_type || 'SCSI',
        index: d.disk_address?.index ?? 0,
      },
      backing_info: {
        $objectType: 'vmm.v4.ahv.config.VmDisk',
        ...V4_RESERVED,
        disk_ext_id: bi.disk_ext_id || legacy.disk_ext_id || uuidv4(),
        disk_size_bytes: bi.disk_size_bytes || legacy.disk_size_bytes || 10737418240,
        ...(dataSource ? { data_source: dataSource } : {}),
        storage_container: {
          ext_id: bi.storage_container?.ext_id || legacy.storage_container?.ext_id || SEED_STORAGE_CONTAINER_ID,
        },
      },
    };
  });

  return {
    ext_id: extId,
    name: b.name || 'unnamed-vm',
    description: b.description || '',
    num_sockets: b.num_sockets || 1,
    num_cores_per_socket: b.num_cores_per_socket || 1,
    memory_size_bytes: b.memory_size_bytes || 4294967296,
    power_state: 'ON',
    cluster: b.cluster || { ext_id: SEED_CLUSTER_ID },
    nics,
    disks,
    boot_config: b.boot_config || {},
    guest_customization: b.guest_customization || {},
    cd_roms: b.cd_roms || [],
    categories: b.categories || [],
    create_time: nowISO(),
    update_time: nowISO(),
  };
}

// Nutanix v4 API envelope helpers
const V4_RESERVED = { $reserved: { $fv: 'v4.r0' } };
const V4_OBJ_TASK_REF = 'prism.v4.config.TaskReference';
const V4_OBJ_TASK     = 'prism.v4.config.Task';
const V4_OBJ_VM       = 'vmm.v4.ahv.config.Vm';

// Networking v4 use different discriminators and reserved versions
const NW_OBJ_PREFIX  = 'networking.v4.config';
const NW_RESERVED    = { $reserved: { $fv: 'v4.r2' } };
const PRISM_RESERVED = { $reserved: { $fv: 'v4.r2' } };

function nwItemEnvelope(obj, objType) {
  const out = deepConvert(obj, toCamelCase);
  out.$objectType = `${NW_OBJ_PREFIX}.${objType}`;
  Object.assign(out, NW_RESERVED);
  return out;
}

function nwListResponse(items, objType, total) {
  return {
    $objectType: `${NW_OBJ_PREFIX}.List${objType}sApiResponse`,
    ...NW_RESERVED,
    data: items.map((v) => nwItemEnvelope(v, objType)),
    metadata: {
      $objectType: 'prism.v4.config.ApiResponseMetadata',
      ...PRISM_RESERVED,
      totalAvailableResults: total ?? items.length,
      offset: 0,
      limit: 50,
    },
  };
}

function nwSingleResponse(item, objType) {
  return {
    $objectType: `${NW_OBJ_PREFIX}.Get${objType}ApiResponse`,
    ...NW_RESERVED,
    data: item ? nwItemEnvelope(item, objType) : null,
    metadata: {
      $objectType: 'prism.v4.config.ApiResponseMetadata',
      ...PRISM_RESERVED,
    },
  };
}

function dataEnvelope(data, objectType) {
  const out = { data: deepConvert(data, toCamelCase) };
  if (objectType) {
    out.data.$objectType = objectType;
    Object.assign(out.data, V4_RESERVED);
  }
  return out;
}

function taskRefEnvelope(extId) {
  return {
    data: {
      $objectType: V4_OBJ_TASK_REF,
      ...PRISM_RESERVED,
      extId,
    },
  };
}

// Networking v4 APIs use a different TaskReference discriminator and reserved
// version than the AHV/VM APIs. The networking Go client checks for
// $objectType == "prism.v4.config.TaskReference" and $reserved.$fv == "v4.r2".
function networkingTaskRefEnvelope(extId) {
  return {
    data: {
      $objectType: 'prism.v4.config.TaskReference',
      $reserved: { $fv: 'v4.r2' },
      extId,
    },
  };
}

function listEnvelope(data, total) {
  return { data: data.map((v) => deepConvert(v, toCamelCase)), metadata: { totalAvailableResults: total ?? data.length, offset: 0, limit: 50 } };
}

// ─── Express app ─────────────────────────────────────────────────────────────
const app = express();
app.use(express.json({ limit: '2mb' }));

// Request logging
app.use((req, _res, next) => {
  // Log how each request authenticated so we can observe cookie reuse vs
  // re-sent Basic auth. Never log the credential itself.
  const auth = req.headers.authorization;
  const cookie = req.headers.cookie;
  let authMode = 'none';
  if (auth) {
    authMode = auth.startsWith('Basic ') ? 'Basic <masked>' : 'auth-header';
  } else if (cookie) {
    const firstName = cookie.split(';')[0].split('=')[0];
    authMode = `cookie(${firstName})`;
  }
  console.log(`[${nowISO()}] ${req.method} ${req.path}  [auth: ${authMode}]`);
  if (req.body && Object.keys(req.body).length > 0) {
    const preview = JSON.stringify(req.body);
    console.log('  body:', preview.length > 400 ? preview.substring(0, 400) + '...' : preview);
  }
  next();
});

// ─── Health check ────────────────────────────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    vms: vmStore.size,
    volume_groups: volumeGroupStore.size,
    recovery_points: recoveryPointStore.size,
    subnets: subnets.size,
    vpcs: vpcStore.size,
    fips: fipStore.size,
    nsps: nspStore.size,
    tasks: taskStore.size,
  });
});

// ─── Session login (cookie auth) ─────────────────────────────────────────────
// Emulates a Prism Central API-gateway session endpoint. A Basic-auth POST
// mints a session cookie (NTNX_IAM_SESSION) so the libcloud driver can switch
// from per-request Basic auth to cookie reuse after its first login.
const SESSION_COOKIE_NAME = 'NTNX_IAM_SESSION';
const sessions = new Map(); // token -> { user, created }

app.post('/api/nutanix/v1/session', (req, res) => {
  const auth = req.headers.authorization || '';
  let user = 'anonymous';
  if (auth.startsWith('Basic ')) {
    const decoded = Buffer.from(auth.slice(6), 'base64').toString('utf-8');
    user = decoded.split(':')[0] || 'anonymous';
  }
  const token = uuidv4();
  sessions.set(token, { user, created: nowISO() });
  res.setHeader('Set-Cookie', `${SESSION_COOKIE_NAME}=${token}; Path=/; HttpOnly`);
  res.json({ data: { user }, metadata: { status: 'SESSION_CREATED' } });
});

// ─── Path builders ───────────────────────────────────────────────────────────
// The Nutanix provider uses /api/vmm/v4.0/ahv/config/vms (ahv, not a1).
// Handle all known variants so the emulator works regardless of SDK version.
function pathVariants(ns, category, resource) {
  return API_VERSIONS.map((v) => `/api/${ns}/${v}/${category}/${resource}`);
}

// ─── VM CRUD ─────────────────────────────────────────────────────────────────
// v4.0 serves VMs on several legacy path variants (a1 / bare / ahv); v4.1+ uses
// the canonical AHV path /api/vmm/v4.x/ahv/config/vms.
const vmListPaths = API_VERSION === 'v4.0'
  ? pathVariants('vmm', 'config', 'vms')
  : [`/api/vmm/${API_VERSION}/ahv/config/vms`];
const vmDetailPaths = vmListPaths.map((p) => p + '/:extId');

// CREATE
app.post(vmListPaths, (req, res) => {
  const snakeBody = deepConvert(req.body, toSnakeCase);
  const vm = buildVmFromCreate(snakeBody, req.body);
  vmStore.set(vm.ext_id, vm);

  const task = makeTask('CREATE', [
    { ext_id: vm.ext_id, rel: 'vm', entity_type: 'virtual_machine' },
  ]);

  console.log(`  -> Created VM ${vm.ext_id}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

// LIST
app.get(vmListPaths, (req, res) => {
  let vms = Array.from(vmStore.values());
  const filter = req.query.$filter;
  if (filter) {
    const m = filter.match(/name eq '(.+?)'/i);
    if (m) vms = vms.filter((vm) => vm.name === m[1]);
  }
  res.json(listEnvelope(vms));
});

// GET one
app.get(vmDetailPaths, (req, res) => {
  const vm = vmStore.get(req.params.extId);
  if (!vm) return res.status(404).json({ message: `VM ${req.params.extId} not found` });
  res.json(dataEnvelope(vm, V4_OBJ_VM));
});

// UPDATE
app.put(vmDetailPaths, (req, res) => {
  const existing = vmStore.get(req.params.extId);
  if (!existing) return res.status(404).json({ message: `VM ${req.params.extId} not found` });

  const snakeBody = deepConvert(req.body, toSnakeCase);
  const merged = { ...existing, ...snakeBody, update_time: nowISO() };
  vmStore.set(merged.ext_id, merged);

  const task = makeTask('UPDATE', [
    { ext_id: merged.ext_id, rel: 'vm', entity_type: 'virtual_machine' },
  ]);

  console.log(`  -> Updated VM ${merged.ext_id}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

// DELETE
app.delete(vmDetailPaths, (req, res) => {
  if (!vmStore.has(req.params.extId)) {
    return res.status(404).json({ message: `VM ${req.params.extId} not found` });
  }
  vmStore.delete(req.params.extId);

  const task = makeTask('DELETE', [
    { ext_id: req.params.extId, rel: 'vm', entity_type: 'virtual_machine' },
  ]);

  console.log(`  -> Deleted VM ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

// VM Power actions
// Power actions — both legacy /power-state/ and v4 /$actions/ URL patterns
const powerPaths = vmDetailPaths.map((p) => p + '/power-state/:action');
const actionsPaths = vmDetailPaths.map((p) => p + '/\\$actions/:action');
const allPowerPaths = [...powerPaths, ...actionsPaths];
app.post(allPowerPaths, (req, res) => {
  const vm = vmStore.get(req.params.extId);
  if (!vm) return res.status(404).json({ message: `VM ${req.params.extId} not found` });

  const powerMap = { 'power-on': 'ON', 'power-off': 'OFF', 'guest-shutdown': 'OFF', 'reset': 'ON', 'guest-reboot': 'ON' };
  if (powerMap[req.params.action]) {
    vm.power_state = powerMap[req.params.action];
    vm.update_time = nowISO();
  }

  const task = makeTask('POWER_ACTION', [
    { ext_id: vm.ext_id, rel: 'vm', entity_type: 'virtual_machine' },
  ]);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

// ─── Tasks ───────────────────────────────────────────────────────────────────
// Task responses must use the prism-go-client discriminator
// ($objectType: "prism.v4.config.Task", $fv: v4.r2) because networking
// resources poll via PrismAPI which expects that exact type.
const V4_OBJ_TASK_PRISM = 'prism.v4.config.Task';
const V4_RESERVED_PRISM = { $reserved: { $fv: 'v4.r2' } };

function prismTaskEnvelope(task) {
  const out = deepConvert(task, toCamelCase);
  out.$objectType = V4_OBJ_TASK_PRISM;
  Object.assign(out, V4_RESERVED_PRISM);
  return { data: out };
}

const taskPaths = pathVariants('prism', 'config', 'tasks').map((p) => p + '/:extId');

app.get(taskPaths, (req, res) => {
  const task = taskStore.get(req.params.extId);
  if (!task) return res.status(404).json({ message: `Task ${req.params.extId} not found` });
  res.json(prismTaskEnvelope(task));
});

// ─── Clusters ────────────────────────────────────────────────────────────────
const clusterPaths = pathVariants('cluster-mgmt', 'config', 'clusters')
  .concat(pathVariants('clustermgmt', 'config', 'clusters'));
const clusterDetailPaths = clusterPaths.map((p) => p + '/:extId');

app.get(clusterPaths, (_req, res) => {
  res.json(listEnvelope(Array.from(clusters.values())));
});
app.get(clusterDetailPaths, (req, res) => {
  const c = clusters.get(req.params.extId);
  if (!c) return res.status(404).json({ message: `Cluster ${req.params.extId} not found` });
  res.json(dataEnvelope(c));
});

// ─── Subnets ─────────────────────────────────────────────────────────────────
const subnetPaths = pathVariants('networking', 'config', 'subnets');
const subnetDetailPaths = subnetPaths.map((p) => p + '/:extId');

app.get(subnetPaths, (req, res) => {
  let items = Array.from(subnets.values());
  const filter = req.query.$filter;
  if (filter) {
    const m = filter.match(/name eq '(.+?)'/i);
    if (m) items = items.filter((s) => s.name === m[1]);
  }
  res.json(nwListResponse(items, 'Subnet'));
});
app.get(subnetDetailPaths, (req, res) => {
  const s = subnets.get(req.params.extId);
  if (!s) return res.status(404).json({ message: `Subnet ${req.params.extId} not found` });
  res.json(nwSingleResponse(s, 'Subnet'));
});

// Subnet CREATE — v4 networking API returns a task
app.post(subnetPaths, (req, res) => {
  const body = deepConvert(req.body, toSnakeCase);
  const extId = uuidv4();

  const subnet = {
    ext_id: extId,
    name: body.name || 'unnamed-subnet',
    description: body.description || '',
    subnet_type: body.subnet_type || 'VLAN',
    cluster_reference: body.cluster_reference || SEED_CLUSTER_ID,
    network_id: body.network_id || null,
    vpc_reference: body.vpc_reference || null,
    is_external: body.is_external || false,
    is_nat_enabled: body.is_nat_enabled || false,
    ip_config: body.ip_config || [],
    dhcp_options: body.dhcp_options || {},
    network_ip: body.ip_config?.[0]?.ipv4?.ip_subnet?.ip?.value || null,
    network_prefix: body.ip_config?.[0]?.ipv4?.ip_subnet?.prefix_length || null,
    gateway_ip: body.ip_config?.[0]?.ipv4?.default_gateway_ip?.value || null,
  };
  subnets.set(extId, subnet);

  const task = makeTask('CREATE', [
    { ext_id: extId, rel: 'subnet', entity_type: 'subnet' },
  ]);
  task.status = 'RUNNING';
  console.log(`  -> Created subnet ${extId}, task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

// Subnet UPDATE
app.put(subnetDetailPaths, (req, res) => {
  const existing = subnets.get(req.params.extId);
  if (!existing) return res.status(404).json({ message: `Subnet ${req.params.extId} not found` });

  const body = deepConvert(req.body, toSnakeCase);
  const merged = { ...existing, ...body };
  subnets.set(req.params.extId, merged);

  const task = makeTask('UPDATE', [
    { ext_id: req.params.extId, rel: 'subnet', entity_type: 'subnet' },
  ]);
  console.log(`  -> Updated subnet ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

// Subnet DELETE
app.delete(subnetDetailPaths, (req, res) => {
  if (!subnets.has(req.params.extId)) {
    return res.status(404).json({ message: `Subnet ${req.params.extId} not found` });
  }
  subnets.delete(req.params.extId);

  const task = makeTask('DELETE', [
    { ext_id: req.params.extId, rel: 'subnet', entity_type: 'subnet' },
  ]);
  console.log(`  -> Deleted subnet ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

// ─── VPCs ────────────────────────────────────────────────────────────────────
const vpcPaths = pathVariants('networking', 'config', 'vpcs');
const vpcDetailPaths = vpcPaths.map((p) => p + '/:extId');

app.get(vpcPaths, (req, res) => {
  let items = Array.from(vpcStore.values());
  const filter = req.query.$filter;
  if (filter) {
    const m = filter.match(/name eq '(.+?)'/i);
    if (m) items = items.filter((v) => v.name === m[1]);
  }
  res.json(nwListResponse(items, 'Vpc'));
});
app.get(vpcDetailPaths, (req, res) => {
  const v = vpcStore.get(req.params.extId);
  if (!v) return res.status(404).json({ message: `VPC ${req.params.extId} not found` });
  res.json(nwSingleResponse(v, 'Vpc'));
});

// VPC CREATE
app.post(vpcPaths, (req, res) => {
  const body = deepConvert(req.body, toSnakeCase);
  const extId = uuidv4();

  const vpc = {
    ext_id: extId,
    name: body.name || 'unnamed-vpc',
    description: body.description || '',
    vpc_type: body.vpc_type || 'REGULAR',
    external_subnets: (body.external_subnets || []).map((es) => ({
      subnet_reference: es.subnet_reference,
      external_ips: es.external_ips || [],
    })),
    externally_routable_prefixes: body.externally_routable_prefixes || [],
    common_dhcp_options: body.common_dhcp_options || {},
  };
  vpcStore.set(extId, vpc);

  const task = makeTask('CREATE', [
    { ext_id: extId, rel: 'vpc', entity_type: 'vpc' },
  ]);
  task.status = 'RUNNING';
  console.log(`  -> Created VPC ${extId}, task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

// VPC UPDATE
app.put(vpcDetailPaths, (req, res) => {
  const existing = vpcStore.get(req.params.extId);
  if (!existing) return res.status(404).json({ message: `VPC ${req.params.extId} not found` });

  const body = deepConvert(req.body, toSnakeCase);
  const merged = { ...existing, ...body };
  vpcStore.set(req.params.extId, merged);

  const task = makeTask('UPDATE', [
    { ext_id: req.params.extId, rel: 'vpc', entity_type: 'vpc' },
  ]);
  console.log(`  -> Updated VPC ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

// VPC DELETE
app.delete(vpcDetailPaths, (req, res) => {
  if (!vpcStore.has(req.params.extId)) {
    return res.status(404).json({ message: `VPC ${req.params.extId} not found` });
  }
  vpcStore.delete(req.params.extId);

  const task = makeTask('DELETE', [
    { ext_id: req.params.extId, rel: 'vpc', entity_type: 'vpc' },
  ]);
  console.log(`  -> Deleted VPC ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

// ─── Floating IPs ────────────────────────────────────────────────────────────
const fipPaths = pathVariants('networking', 'config', 'floating-ips');
const fipDetailPaths = fipPaths.map((p) => p + '/:extId');

app.get(fipPaths, (req, res) => {
  let items = Array.from(fipStore.values());
  const filter = req.query.$filter;
  if (filter) {
    const m = filter.match(/name eq '(.+?)'/i);
    if (m) items = items.filter((f) => f.name === m[1]);
  }
  res.json(nwListResponse(items, 'FloatingIp'));
});
app.get(fipDetailPaths, (req, res) => {
  const f = fipStore.get(req.params.extId);
  if (!f) return res.status(404).json({ message: `Floating IP ${req.params.extId} not found` });
  res.json(nwSingleResponse(f, 'FloatingIp'));
});

app.post(fipPaths, (req, res) => {
  const body = deepConvert(req.body, toSnakeCase);
  const extId = uuidv4();
  const ip = `192.168.0.${Math.floor(Math.random() * 200) + 30}`;

  const fip = {
    ext_id: extId,
    name: body.name || 'unnamed-fip',
    description: body.description || '',
    ipv4: { value: ip },
    external_subnet_reference: body.external_subnet_reference || '',
    association: body.association || null,
  };
  fipStore.set(extId, fip);

  const task = makeTask('CREATE', [
    { ext_id: extId, rel: 'floating_ip', entity_type: 'floating_ip' },
  ]);
  task.status = 'RUNNING';
  console.log(`  -> Created floating IP ${extId} (${ip}), task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

app.delete(fipDetailPaths, (req, res) => {
  if (!fipStore.has(req.params.extId)) {
    return res.status(404).json({ message: `Floating IP ${req.params.extId} not found` });
  }
  fipStore.delete(req.params.extId);

  const task = makeTask('DELETE', [
    { ext_id: req.params.extId, rel: 'floating_ip', entity_type: 'floating_ip' },
  ]);
  console.log(`  -> Deleted floating IP ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

// ─── Network Security Policies ───────────────────────────────────────────────
const nspPaths = pathVariants('microseg', 'config', 'policies');
const nspDetailPaths = nspPaths.map((p) => p + '/:extId');

app.get(nspPaths, (req, res) => {
  let items = Array.from(nspStore.values());
  const filter = req.query.$filter;
  if (filter) {
    const m = filter.match(/name eq '(.+?)'/i);
    if (m) items = items.filter((n) => n.name === m[1]);
  }
  res.json(nwListResponse(items, 'NetworkSecurityPolicy'));
});
app.get(nspDetailPaths, (req, res) => {
  const n = nspStore.get(req.params.extId);
  if (!n) return res.status(404).json({ message: `NSP ${req.params.extId} not found` });
  res.json(nwSingleResponse(n, 'NetworkSecurityPolicy'));
});

app.post(nspPaths, (req, res) => {
  const body = deepConvert(req.body, toSnakeCase);
  const extId = uuidv4();

  const nsp = {
    ext_id: extId,
    name: body.name || 'unnamed-nsp',
    description: body.description || '',
    type: body.type || 'APPLICATION',
    state: body.state || 'SAVE',
    rules: body.rules || [],
    vpc_reference: body.vpc_reference || [],
    is_hitlog_enabled: body.is_hitlog_enabled || false,
  };
  nspStore.set(extId, nsp);

  const task = makeTask('CREATE', [
    { ext_id: extId, rel: 'network_security_policy', entity_type: 'network_security_policy' },
  ]);
  task.status = 'RUNNING';
  console.log(`  -> Created NSP ${extId}, task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

app.delete(nspDetailPaths, (req, res) => {
  if (!nspStore.has(req.params.extId)) {
    return res.status(404).json({ message: `NSP ${req.params.extId} not found` });
  }
  nspStore.delete(req.params.extId);

  const task = makeTask('DELETE', [
    { ext_id: req.params.extId, rel: 'network_security_policy', entity_type: 'network_security_policy' },
  ]);
  console.log(`  -> Deleted NSP ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(networkingTaskRefEnvelope(task.ext_id));
});

// ─── Images (legacy config path + v4 content path) ───────────────────────────
const imagePaths = pathVariants('vmm', 'config', 'images')
  .concat([`/api/vmm/${API_VERSION}/content/images`]);
const imageDetailPaths = imagePaths.map((p) => p + '/:extId');

function imageSummary(img) {
  return {
    ext_id: img.ext_id,
    name: img.name,
    description: img.description,
    image_type: img.image_type,
    type: img.image_type,
    size_bytes: img.size_bytes,
    create_time: img.create_time,
    last_update_time: img.last_update_time,
    cluster_location_ext_ids: img.cluster_location_ext_ids || [],
    source: img.source || null,
  };
}

function buildImageFromCreate(body) {
  const extId = uuidv4();
  const source = body.source || {};
  let sizeBytes = body.size_bytes || body.sizeBytes || 0;
  if (!sizeBytes && source.url) {
    sizeBytes = 1073741824;
  } else if (!sizeBytes && (source.ext_id || source.extId)) {
    sizeBytes = 8589934592;
  }

  return {
    ext_id: extId,
    name: body.name || 'unnamed-image',
    description: body.description || '',
    image_type: body.type || body.image_type || 'DISK_IMAGE',
    size_bytes: sizeBytes,
    cluster_location_ext_ids: body.cluster_location_ext_ids || body.clusterLocationExtIds || [],
    source,
    create_time: nowISO(),
    last_update_time: nowISO(),
  };
}

app.get(imagePaths, (_req, res) => {
  res.json(listEnvelope(Array.from(images.values()).map(imageSummary)));
});
app.get(imageDetailPaths, (req, res) => {
  const img = images.get(req.params.extId);
  if (!img) return res.status(404).json({ message: `Image ${req.params.extId} not found` });
  res.json(dataEnvelope(imageSummary(img)));
});

app.post([`/api/vmm/${API_VERSION}/content/images`], (req, res) => {
  const body = deepConvert(req.body, toSnakeCase);
  const source = body.source || {};

  if (source.ext_id || source.extId) {
    const diskExtId = source.ext_id || source.extId;
    let found = false;
    for (const vm of vmStore.values()) {
      for (const disk of vm.disks || []) {
        const backing = disk.backing_info || {};
        const legacy = backing.vm_disk || {};
        if (
          disk.ext_id === diskExtId
          || backing.disk_ext_id === diskExtId
          || legacy.disk_ext_id === diskExtId
        ) {
          found = true;
          break;
        }
      }
      if (found) break;
    }
    if (!found) {
      return res.status(404).json({ message: `VM disk ${diskExtId} not found` });
    }
  }

  const img = buildImageFromCreate(body);
  images.set(img.ext_id, img);

  const task = makeTask(
    'CREATE',
    [{ ext_id: img.ext_id, rel: 'image', entity_type: 'image' }],
    { completionDetails: [{ name: 'imageExtId', value: img.ext_id }] },
  );
  console.log(`  -> Created image ${img.ext_id}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

app.delete([`/api/vmm/${API_VERSION}/content/images/:extId`], (req, res) => {
  if (!images.has(req.params.extId)) {
    return res.status(404).json({ message: `Image ${req.params.extId} not found` });
  }
  images.delete(req.params.extId);

  const task = makeTask('DELETE', [
    { ext_id: req.params.extId, rel: 'image', entity_type: 'image' },
  ]);
  console.log(`  -> Deleted image ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

// ─── Storage containers ──────────────────────────────────────────────────────
const scPaths = pathVariants('clustermgmt', 'config', 'storage-containers')
  .concat(pathVariants('vmm', 'config', 'storage-containers'))
  .concat(pathVariants('cluster-mgmt', 'config', 'storage-containers'));
const scDetailPaths = scPaths.map((p) => p + '/:extId');

app.get(scPaths, (_req, res) => {
  res.json(listEnvelope(Array.from(storageContainers.values())));
});
app.get(scDetailPaths, (req, res) => {
  const sc = storageContainers.get(req.params.extId);
  if (!sc) return res.status(404).json({ message: `Storage container ${req.params.extId} not found` });
  res.json(dataEnvelope(sc));
});

// ─── Volume groups (volumes v4) ──────────────────────────────────────────────
const vgListPaths = [`/api/volumes/${API_VERSION}/config/volume-groups`];
const vgDetailPaths = vgListPaths.map((p) => p + '/:extId');
const vgDiskPaths = vgListPaths.map((p) => p + '/:volumeGroupExtId/disks');
const vgAttachmentPaths = vgListPaths.map((p) => p + '/:volumeGroupExtId/vm-attachments');
const vgAttachVmPaths = vgListPaths.map((p) => p + '/:extId/$actions/attach-vm');
const vgDetachVmPaths = vgListPaths.map((p) => p + '/:extId/$actions/detach-vm');

function buildVolumeGroupFromCreate(body) {
  const extId = uuidv4();
  const rawDisks = body.disks || [];
  const disks = rawDisks.map((disk, index) => ({
    ext_id: uuidv4(),
    index: disk.index ?? index,
    disk_size_bytes: disk.disk_size_bytes || disk.diskSizeBytes || 10737418240,
    storage_container_id: disk.storage_container_id || disk.storageContainerId || SEED_STORAGE_CONTAINER_ID,
  }));
  if (disks.length === 0) {
    disks.push({
      ext_id: uuidv4(),
      index: 0,
      disk_size_bytes: 10737418240,
      storage_container_id: SEED_STORAGE_CONTAINER_ID,
    });
  }

  return {
    ext_id: extId,
    name: body.name || 'unnamed-volume-group',
    description: body.description || '',
    cluster_reference: body.cluster_reference || body.clusterReference || SEED_CLUSTER_ID,
    disks,
    vm_attachments: [],
    create_time: nowISO(),
    update_time: nowISO(),
  };
}

function volumeGroupSummary(vg) {
  return {
    ext_id: vg.ext_id,
    name: vg.name,
    description: vg.description,
    cluster_reference: vg.cluster_reference,
    sharing_status: vg.sharing_status || 'NOT_SHARED',
    usage_type: vg.usage_type || 'USER',
    create_time: vg.create_time,
    update_time: vg.update_time,
  };
}

app.post(vgListPaths, (req, res) => {
  const body = deepConvert(req.body, toSnakeCase);
  const vg = buildVolumeGroupFromCreate(body);
  volumeGroupStore.set(vg.ext_id, vg);

  const task = makeTask('CREATE', [
    { ext_id: vg.ext_id, rel: 'volume_group', entity_type: 'volume_group' },
  ]);
  console.log(`  -> Created volume group ${vg.ext_id}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

app.get(vgListPaths, (req, res) => {
  let items = Array.from(volumeGroupStore.values()).map(volumeGroupSummary);
  const filter = req.query.$filter;
  if (filter) {
    const m = filter.match(/name eq '(.+?)'/i);
    if (m) items = items.filter((vg) => vg.name === m[1]);
  }
  res.json(listEnvelope(items));
});

app.get(vgDetailPaths, (req, res) => {
  const vg = volumeGroupStore.get(req.params.extId);
  if (!vg) return res.status(404).json({ message: `Volume group ${req.params.extId} not found` });
  res.json(dataEnvelope(volumeGroupSummary(vg)));
});

app.delete(vgDetailPaths, (req, res) => {
  if (!volumeGroupStore.has(req.params.extId)) {
    return res.status(404).json({ message: `Volume group ${req.params.extId} not found` });
  }
  volumeGroupStore.delete(req.params.extId);

  const task = makeTask('DELETE', [
    { ext_id: req.params.extId, rel: 'volume_group', entity_type: 'volume_group' },
  ]);
  console.log(`  -> Deleted volume group ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

app.get(vgDiskPaths, (req, res) => {
  const vg = volumeGroupStore.get(req.params.volumeGroupExtId);
  if (!vg) {
    return res.status(404).json({ message: `Volume group ${req.params.volumeGroupExtId} not found` });
  }
  res.json(listEnvelope(vg.disks || []));
});

app.get(vgAttachmentPaths, (req, res) => {
  const vg = volumeGroupStore.get(req.params.volumeGroupExtId);
  if (!vg) {
    return res.status(404).json({ message: `Volume group ${req.params.volumeGroupExtId} not found` });
  }
  res.json(listEnvelope(vg.vm_attachments || []));
});

app.post(vgAttachVmPaths, (req, res) => {
  const vg = volumeGroupStore.get(req.params.extId);
  if (!vg) return res.status(404).json({ message: `Volume group ${req.params.extId} not found` });

  const body = deepConvert(req.body, toSnakeCase);
  const vmExtId = body.ext_id || body.extId;
  if (!vmExtId) return res.status(422).json({ message: 'VM extId is required' });
  if (!vmStore.has(vmExtId)) return res.status(404).json({ message: `VM ${vmExtId} not found` });

  vg.vm_attachments = (vg.vm_attachments || []).filter((item) => item.ext_id !== vmExtId);
  vg.vm_attachments.push({
    ext_id: vmExtId,
    index: body.index ?? 0,
  });
  vg.update_time = nowISO();
  volumeGroupStore.set(vg.ext_id, vg);

  const task = makeTask('UPDATE', [
    { ext_id: vg.ext_id, rel: 'volume_group', entity_type: 'volume_group' },
    { ext_id: vmExtId, rel: 'vm', entity_type: 'virtual_machine' },
  ]);
  console.log(`  -> Attached VM ${vmExtId} to volume group ${vg.ext_id}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

app.post(vgDetachVmPaths, (req, res) => {
  const vg = volumeGroupStore.get(req.params.extId);
  if (!vg) return res.status(404).json({ message: `Volume group ${req.params.extId} not found` });

  const body = deepConvert(req.body, toSnakeCase);
  const vmExtId = body.ext_id || body.extId;
  if (!vmExtId) return res.status(422).json({ message: 'VM extId is required' });

  vg.vm_attachments = (vg.vm_attachments || []).filter((item) => item.ext_id !== vmExtId);
  vg.update_time = nowISO();
  volumeGroupStore.set(vg.ext_id, vg);

  const task = makeTask('UPDATE', [
    { ext_id: vg.ext_id, rel: 'volume_group', entity_type: 'volume_group' },
    { ext_id: vmExtId, rel: 'vm', entity_type: 'virtual_machine' },
  ]);
  console.log(`  -> Detached VM ${vmExtId} from volume group ${vg.ext_id}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

// ─── Recovery points (dataprotection v4) ─────────────────────────────────────
const rpListPaths = [`/api/dataprotection/${API_VERSION}/config/recovery-points`];
const rpDetailPaths = rpListPaths.map((p) => p + '/:extId');

function recoveryPointSummary(rp) {
  return {
    ext_id: rp.ext_id,
    name: rp.name,
    status: rp.status || 'COMPLETE',
    creation_time: rp.creation_time,
    expiration_time: rp.expiration_time || null,
    recovery_point_type: rp.recovery_point_type || 'CRASH_CONSISTENT',
    volume_group_recovery_points: rp.volume_group_recovery_points || [],
  };
}

function recoveryPointMatchesVolumeGroup(rp, volumeGroupExtId) {
  return (rp.volume_group_recovery_points || []).some(
    (item) => item.volume_group_ext_id === volumeGroupExtId
  );
}

app.post(rpListPaths, (req, res) => {
  const body = deepConvert(req.body, toSnakeCase);
  const extId = uuidv4();
  const volumeGroupRecoveryPoints = (body.volume_group_recovery_points || []).map((item) => ({
    ext_id: uuidv4(),
    volume_group_ext_id: item.volume_group_ext_id || item.volumeGroupExtId,
    name: body.name,
  }));

  const rp = {
    ext_id: extId,
    name: body.name || 'recovery-point',
    status: 'COMPLETE',
    creation_time: nowISO(),
    recovery_point_type: 'CRASH_CONSISTENT',
    volume_group_recovery_points: volumeGroupRecoveryPoints,
  };
  recoveryPointStore.set(extId, rp);

  const task = makeTask(
    'CREATE',
    [{ ext_id: extId, rel: 'recovery_point', entity_type: 'recovery_point' }],
    { completionDetails: [{ name: 'recoveryPointExtId', value: extId }] },
  );
  console.log(`  -> Created recovery point ${extId}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

app.get(rpListPaths, (req, res) => {
  let items = Array.from(recoveryPointStore.values());
  const filter = req.query.$filter;
  if (filter) {
    const m = filter.match(/volumeGroupExtId eq '(.+?)'/i);
    if (m) {
      items = items.filter((rp) => recoveryPointMatchesVolumeGroup(rp, m[1]));
    }
  }
  res.json(listEnvelope(items.map(recoveryPointSummary)));
});

app.get(rpDetailPaths, (req, res) => {
  const rp = recoveryPointStore.get(req.params.extId);
  if (!rp) return res.status(404).json({ message: `Recovery point ${req.params.extId} not found` });
  res.json(dataEnvelope(recoveryPointSummary(rp)));
});

app.delete(rpDetailPaths, (req, res) => {
  if (!recoveryPointStore.has(req.params.extId)) {
    return res.status(404).json({ message: `Recovery point ${req.params.extId} not found` });
  }
  recoveryPointStore.delete(req.params.extId);

  const task = makeTask('DELETE', [
    { ext_id: req.params.extId, rel: 'recovery_point', entity_type: 'recovery_point' },
  ]);
  console.log(`  -> Deleted recovery point ${req.params.extId}, task ${task.ext_id}`);
  res.status(202).json(taskRefEnvelope(task.ext_id));
});

// ─── Auth bypass ─────────────────────────────────────────────────────────────
app.use((_req, _res, next) => { next(); });

// ─── Catch-all proxy to Prism ────────────────────────────────────────────────
// NOTE: express.json() above consumes the request body stream, so we must
// re-write it in proxyReq for POST/PATCH/PUT/DELETE requests that carry a body.
app.use(
  '/',
  createProxyMiddleware({
    target: PRISM_URL,
    changeOrigin: true,
    on: {
      proxyReq: (proxyReq, req) => {
        console.log(`  -> proxying to Prism: ${req.method} ${req.path}`);
        // Re-write body that was consumed by express.json()
        if (req.body && Object.keys(req.body).length > 0 && ['POST','PATCH','PUT','DELETE'].includes(req.method)) {
          const bodyData = JSON.stringify(req.body);
          proxyReq.setHeader('Content-Type', 'application/json');
          proxyReq.setHeader('Content-Length', Buffer.byteLength(bodyData));
          proxyReq.write(bodyData);
        }
      },
      error: (err, _req, res) => {
        console.error('  x Prism proxy error:', err.message);
        if (!res.headersSent) {
          res.status(502).json({ message: 'Prism unavailable', error: err.message });
        }
      },
    },
  })
);

// ─── Start (HTTPS) ───────────────────────────────────────────────────────────
const certPath = process.env.TLS_CERT || '/app/cert.pem';
const keyPath = process.env.TLS_KEY || '/app/key.pem';

let server;
if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
  const tlsOpts = { cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) };
  server = https.createServer(tlsOpts, app);
  console.log('TLS enabled (self-signed certificate)');
} else {
  // Fallback to HTTP if no certs (useful for smoke tests from host)
  const http = require('http');
  server = http.createServer(app);
  console.log('WARNING: running without TLS (HTTP mode)');
}

server.listen(PORT, () => {
  const proto = server instanceof https.Server ? 'https' : 'http';
  console.log('');
  console.log('╔══════════════════════════════════════════════════════╗');
  console.log(`║   Nutanix VM Emulator (${proto.padEnd(4)})                        ║`);
  console.log('║   Port: ' + String(PORT).padEnd(44) + '║');
  console.log('║   Prism upstream: ' + PRISM_URL.padEnd(34) + '║');
  console.log('║   Seed cluster:   ' + SEED_CLUSTER_ID + '  ║');
  console.log('║   Seed subnet:    ' + SEED_SUBNET_ID + '  ║');
  console.log('║   Seed image:     ' + SEED_IMAGE_ID + '  ║');
  console.log('║   Seed stor-cont: ' + SEED_STORAGE_CONTAINER_ID + '  ║');
  console.log('╚══════════════════════════════════════════════════════╝');
  console.log('');
});
