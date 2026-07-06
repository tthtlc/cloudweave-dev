#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const V40_DIR = path.resolve('/work/mock/v40');
const OUTPUT_FILE = path.resolve('/work/spec/openapi.json');

// All Nutanix v4.0 spec files to merge
const SPEC_FILES = [
  'swagger-vmm-v4.0-all.yaml',
  'swagger-networking-v4.0-all.yaml',
  'swagger-clustermgmt-v4.0-all.yaml',
  'swagger-prism-v4.0-all.yaml',
  'swagger-storage-v4.0.a3-all.yaml',
  'swagger-volumes-v4.0-all.yaml',
  'swagger-iam-v4.0-all.yaml',
  'swagger-files-v4.0-all.yaml',
  'swagger-security-v4.0-all.yaml',
  'swagger-monitoring-v4.0-all.yaml',
  'swagger-licensing-v4.0-all.yaml',
  'swagger-aiops-v4.0-all.yaml',
  'swagger-datapolicies-v4.0-all.yaml',
  'swagger-dataprotection-v4.0-all.yaml',
  'swagger-lifecycle-v4.0-all.yaml',
  'swagger-microseg-v4.0-all.yaml',
  'swagger-objects-v4.0-all.yaml',
  'swagger-opsmgmt-v4.0-all.yaml',
  'swagger-multidomain-v4.2-all.yaml',
];

function mergeSpecs() {
  const merged = {
    openapi: '3.0.1',
    info: {
      title: 'Nutanix v4 API - Merged Mock Spec',
      description:
        'Merged OpenAPI specification combining all Nutanix v4.0 namespace specs ' +
        '(vmm, networking, cluster-mgmt, prism, storage, volumes, iam, files, security, ' +
        'monitoring, licensing, aiops, datapolicies, dataprotection, lifecycle, microseg, ' +
        'objects, opsmgmt, multidomain). Used by Stoplight Prism for API mocking.',
      version: '4.0',
    },
    servers: [
      {
        url: 'http://localhost:4010',
        description: 'Prism mock server',
      },
    ],
    paths: {},
    components: {
      schemas: {},
    },
    tags: [],
  };

  const stats = { paths: 0, schemas: 0, tags: 0, failed: [] };

  for (const file of SPEC_FILES) {
    const filePath = path.join(V40_DIR, file);
    if (!fs.existsSync(filePath)) {
      console.warn(`  SKIP: ${file} (not found)`);
      continue;
    }

    try {
      console.log(`  Reading ${file}...`);
      const raw = fs.readFileSync(filePath, 'utf8');
      const content = yaml.load(raw);

      if (!content || typeof content !== 'object') {
        console.warn(`  WARN: ${file} parsed to empty/non-object, skipping`);
        continue;
      }

      // Merge paths — add /api prefix to match Nutanix API URL structure.
      // The YAML specs define paths like /vmm/v4.0/... with servers[0].url
      // ending in /api. Prism matches against the full request path, so we
      // prepend /api to every path so they match the actual request URIs.
      if (content.paths && typeof content.paths === 'object') {
        let pathCount = 0;
        for (const [specPath, specPathItem] of Object.entries(content.paths)) {
          const apiPath = '/api' + specPath;
          merged.paths[apiPath] = specPathItem;
          pathCount++;
        }
        stats.paths += pathCount;
        console.log(`    -> ${pathCount} paths (prefixed /api)`);
      }

      // Merge components — only schemas; skip securitySchemes so Prism
      // doesn't enforce auth on mock responses.
      if (content.components && typeof content.components === 'object') {
        if (content.components.schemas && typeof content.components.schemas === 'object') {
          const schemaCount = Object.keys(content.components.schemas).length;
          Object.assign(merged.components.schemas, content.components.schemas);
          stats.schemas += schemaCount;
        }
      }

      // Merge tags (deduplicate by name)
      if (Array.isArray(content.tags)) {
        const knownTags = new Set(merged.tags.map((t) => t.name));
        for (const tag of content.tags) {
          if (!knownTags.has(tag.name)) {
            merged.tags.push(tag);
            stats.tags++;
            knownTags.add(tag.name);
          }
        }
      }

      // Deliberately skip security, securitySchemes, responses, parameters,
      // requestBodies, and headers to avoid Prism enforcing auth or other
      // server-side constraints on the mock.
    } catch (err) {
      console.error(`  FAIL: ${file} - ${err.message}`);
      stats.failed.push(file);
    }
  }

  console.log('');
  console.log('═══════════════════════════════════════');
  console.log(`  Total paths:   ${Object.keys(merged.paths).length} (all prefixed /api)`);
  console.log(`  Total schemas: ${Object.keys(merged.components.schemas).length}`);
  console.log(`  Total tags:    ${merged.tags.length}`);
  if (stats.failed.length > 0) {
    console.log(`  Failed files:  ${stats.failed.join(', ')}`);
  }
  console.log('═══════════════════════════════════════');

  // Write merged spec
  const json = JSON.stringify(merged, null, 2);
  fs.writeFileSync(OUTPUT_FILE, json, 'utf8');

  const sizeKB = (Buffer.byteLength(json, 'utf8') / 1024).toFixed(1);
  console.log(`\nWrote ${OUTPUT_FILE} (${sizeKB} KB)`);
}

mergeSpecs();
