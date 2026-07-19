#!/usr/bin/env python3
"""
openfga_bootstrap.py
====================

Idempotent bootstrap for an OpenFGA deployment via the OpenFGA REST API.

What it does
------------
1. Initializes (or reuses) a named store.
2. Registers the libcloud REST API authorization model (idempotent — skips if an
   identical model is already the latest one).
3. Populates initial relationship tuples for tenant membership, API access,
   Nutanix provider use, and cluster provisioning (idempotent).
4. Runs a validation loop that issues Check() calls to confirm the deployed
   model + tuples behave as expected, with bounded retry/backoff to absorb
   eventual-consistency / propagation lag.

Authorization model
-------------------
The model mirrors ../libcloud.rest access control and the four-role taxonomy
in rbac_design.md (SuperAdmin / Owner / Admin / Viewer) with per-resource-class
sub-roles:

  user -> tenant -> libcloud_api.can_connect
  user -> tenant -> provider.can_use -> (aws_region|nutanix_cluster).can_provision
  user -> tenant -> provider.can_use -> (aws_region|nutanix_cluster).can_update   (edit; owner∪admin)
  user -> resource_class -> (aws_region|nutanix_cluster).can_provision   (per-class)
  user -> resource_class -> (aws_region|nutanix_cluster).can_update        (per-class edit)
  user -> platform:main#superadmin -> global_reader -> can_read everywhere

Sample users seeded by this script (stable OpenFGA principal slugs):

  superadmin     platform SuperAdmin (global read-only + governance; not a tenant owner)
  aws-owner      owner  of tenant:aws      -> full AWS CRUD + membership
  aws-admin      admin  of tenant:aws       -> provision AWS, no membership changes
  aws-viewer     viewer of tenant:aws       -> enumerate AWS only
  ntnx-owner     owner  of tenant:nutanix
  ntnx-admin     admin  of tenant:nutanix
  ntnx-viewer    viewer of tenant:nutanix
  cloud-denied   authenticated in Dex but no OpenFGA tuples (denied)
  aws-compute-admin   OpenFGA-only principal: admin  on resource_class:aws-compute
  ntnx-compute-viewer OpenFGA-only principal: viewer on resource_class:nutanix-compute

Design notes
------------
* Pure stdlib HTTP via urllib so there are zero third-party dependencies;
  if `requests` is installed it is *not* required.
* Robust error handling: distinguishes 4xx (config/validation) from 5xx
  (transient) errors, with retry + exponential backoff for retryable cases.
* Safe to run repeatedly — every mutating step checks current state first.

Environment variables
----------------------
  FGA_API_URL    Base URL of the OpenFGA server   (default http://localhost:8080)
  FGA_API_TOKEN  Optional bearer token (preshared-key / OIDC access token)
  FGA_STORE_NAME Logical store name to create/reuse (default "libcloud-rest-store")

Usage
-----
  python openfga_bootstrap.py
  FGA_API_URL=https://fga.example.com FGA_API_TOKEN=xxx python openfga_bootstrap.py
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #
logging.basicConfig(
    level=os.environ.get("FGA_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("openfga-bootstrap")


# --------------------------------------------------------------------------- #
# Exceptions
# --------------------------------------------------------------------------- #
class FgaError(Exception):
    """Base class for all bootstrap errors."""


class FgaHttpError(FgaError):
    def __init__(self, status: int, method: str, path: str, body: str):
        self.status = status
        self.method = method
        self.path = path
        self.body = body
        super().__init__(f"{method} {path} -> HTTP {status}: {body}")

    @property
    def retryable(self) -> bool:
        # 5xx and 429 are worth retrying; 4xx (except 429) are caller errors.
        return self.status >= 500 or self.status == 429


class FgaValidationError(FgaError):
    """Raised when post-deploy validation expectations are not met."""


# --------------------------------------------------------------------------- #
# Low-level HTTP client
# --------------------------------------------------------------------------- #
@dataclass
class FgaClient:
    base_url: str
    token: Optional[str] = None
    timeout: float = 15.0
    max_retries: int = 5
    backoff_base: float = 0.5  # seconds

    def _headers(self) -> Dict[str, str]:
        h = {"Content-Type": "application/json", "Accept": "application/json"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    def request(
        self,
        method: str,
        path: str,
        payload: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Perform an HTTP request with retry/backoff on transient failures."""
        url = self.base_url.rstrip("/") + path
        data = json.dumps(payload).encode("utf-8") if payload is not None else None

        last_exc: Optional[Exception] = None
        for attempt in range(1, self.max_retries + 1):
            req = urllib.request.Request(
                url, data=data, method=method, headers=self._headers()
            )
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    raw = resp.read().decode("utf-8") or "{}"
                    return json.loads(raw)
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8", errors="replace")
                err = FgaHttpError(e.code, method, path, body)
                if err.retryable and attempt < self.max_retries:
                    delay = self.backoff_base * (2 ** (attempt - 1))
                    log.warning(
                        "%s %s transient HTTP %s (attempt %d/%d) — retrying in %.1fs",
                        method, path, e.code, attempt, self.max_retries, delay,
                    )
                    time.sleep(delay)
                    last_exc = err
                    continue
                raise err
            except urllib.error.URLError as e:
                # Network-level failure (connection refused, DNS, timeout).
                last_exc = e
                if attempt < self.max_retries:
                    delay = self.backoff_base * (2 ** (attempt - 1))
                    log.warning(
                        "%s %s network error: %s (attempt %d/%d) — retrying in %.1fs",
                        method, path, e, attempt, self.max_retries, delay,
                    )
                    time.sleep(delay)
                    continue
                raise FgaError(f"Network failure calling {method} {path}: {e}") from e

        # Should be unreachable, but guard anyway.
        raise FgaError(f"Exhausted retries for {method} {path}: {last_exc}")

    # -- Convenience verbs -------------------------------------------------- #
    def get(self, path: str) -> Dict[str, Any]:
        return self.request("GET", path)

    def post(self, path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        return self.request("POST", path, payload)


# --------------------------------------------------------------------------- #
# libcloud REST API authorization model (schema 1.1)
# --------------------------------------------------------------------------- #
# Hierarchical privilege model (per rbac_design.md):
#
#   platform:main
#     superadmin   -> bootstrap identity (LLDAP uid=superadmin). Meta-operator:
#                     gates Vault seeding, OpenFGA tuple changes, LLDAP user
#                     CRUD, tenant lifecycle, global policy, IAM mappings, and
#                     owner assignment on every tenant. NOT a tenant owner by
#                     default — gets global read-only visibility instead.
#     global_reader -> computedUserset(superadmin); feeds can_connect /
#                     can_use / can_read everywhere, but NOT can_provision.
#   tenant:aws / tenant:nutanix
#     owner        -> per-cloud owner; can assign admin/viewer; can provision.
#                     can_assign_owner is SuperAdmin-gated, NOT owner-grantable.
#     admin        -> per-cloud admin; can provision; CANNOT change membership
#                     (no assign-owner/admin/viewer).
#     viewer       -> per-cloud viewer; read / enumerate only.
#   resource_class:<tenant>-<class>
#     admin / viewer -> per-class Admin/Viewer sub-roles (compute/network/data/
#                     platform). Backends union their can_provision/can_read with
#                     the bound resource_class's, so an Admin can be narrowed to
#                     a single resource class.
#
# Runtime relations enforced by ../libcloud.rest/app/auth/policy.py are
# preserved: can_connect (libcloud_api:main), can_use (provider:*),
# can_provision / can_read (aws_region:* / nutanix_cluster:*). Tenant roles
# propagate to backends via the `tenant` relation on each backend object;
# platform:main parents every object so SuperAdmin's global_reader and
# can_manage_platform reach them.
LIBCLOUD_MODEL: Dict[str, Any] = {
    "schema_version": "1.1",
    "type_definitions": [
        {"type": "user"},
        {
            "type": "platform",
            "relations": {
                "superadmin": {"this": {}},
                # Global read-only visibility of every tenant and its resources,
                # granted by virtue of being SuperAdmin (rbac_design.md:32-34).
                # Feeds can_connect / can_use / can_read on tenants, providers,
                # backends and resource classes — but NOT can_provision, so a
                # SuperAdmin can observe all tenants yet cannot provision inside
                # any of them unless explicitly granted a tenant role.
                "global_reader": {"computedUserset": {"relation": "superadmin"}},
                "can_manage_platform": {"computedUserset": {"relation": "superadmin"}},
                # Tenant lifecycle: create / onboard / decommission tenants
                # (register AWS accounts, Nutanix projects). rbac_design.md:27-29
                "can_manage_tenant_lifecycle": {
                    "computedUserset": {"relation": "superadmin"}
                },
                # Global policies: password/SSO/IdP, logging, guardrails, quotas,
                # compliance baselines, RBAC templates. rbac_design.md:30, 37
                "can_manage_global_policy": {
                    "computedUserset": {"relation": "superadmin"}
                },
                # Mappings between this RBAC engine and AWS IAM / Nutanix Prism
                # roles. rbac_design.md:38
                "can_manage_iam_mapping": {"computedUserset": {"relation": "superadmin"}},
            },
            "metadata": {
                "relations": {
                    "superadmin": {
                        "directly_related_user_types": [{"type": "user"}]
                    },
                }
            },
        },
        {
            "type": "tenant",
            "relations": {
                # platform:main is the parent that gates cross-tenant SuperAdmin
                # capabilities (assign-owner, global read) on this tenant.
                "platform": {"this": {}},
                "owner": {"this": {}},
                "admin": {"this": {}},
                "viewer": {"this": {}},
                "member": {
                    "union": {
                        "child": [
                            {"this": {}},
                            {"computedUserset": {"relation": "owner"}},
                            {"computedUserset": {"relation": "admin"}},
                            {"computedUserset": {"relation": "viewer"}},
                        ]
                    }
                },
                # Assigning/revokeing tenant Owners is reserved for SuperAdmin
                # (rbac_design.md:28-29). A tenant Owner can no longer mint
                # co-Owners (closes the privilege-escalation path noted in
                # rbac_design_modified1.md contradiction #2).
                "can_assign_owner": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "platform"},
                        "computedUserset": {"relation": "can_manage_platform"},
                    }
                },
                "can_assign_admin": {"computedUserset": {"relation": "owner"}},
                # Only Owners assign/revoke Viewer. Admins cannot change tenant
                # membership at all (rbac_design.md:93-97), so the admin arm is
                # dropped (rbac_design_modified1.md contradiction #3).
                "can_assign_viewer": {"computedUserset": {"relation": "owner"}},
                # Backend cloud credentials for this tenant may only be updated
                # by the tenant owner. SuperAdmin is no longer seeded as an
                # owner, so it must be explicitly granted the owner role on a
                # tenant to manage that tenant's credentials (break-glass).
                "can_manage_credentials": {"computedUserset": {"relation": "owner"}},
                "can_provision": {
                    "union": {
                        "child": [
                            {"computedUserset": {"relation": "admin"}},
                            {"computedUserset": {"relation": "owner"}},
                        ]
                    }
                },
                # Update (edit) is a distinct write verb from create/delete
                # (rbac_design.md §Deprovisioning / changelog #10). At present
                # Owner and Admin can update; Viewer and SuperAdmin (by default)
                # cannot. Modeled parallel to can_provision so a per-class Admin
                # also gains can_update via the resource_class arm on backends.
                "can_update": {
                    "union": {
                        "child": [
                            {"computedUserset": {"relation": "admin"}},
                            {"computedUserset": {"relation": "owner"}},
                        ]
                    }
                },
                "can_read": {
                    "union": {
                        "child": [
                            {"computedUserset": {"relation": "viewer"}},
                            {"computedUserset": {"relation": "admin"}},
                            {"computedUserset": {"relation": "owner"}},
                            # SuperAdmin global read-only visibility.
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "platform"},
                                    "computedUserset": {"relation": "global_reader"},
                                }
                            },
                        ]
                    }
                },
            },
            "metadata": {
                "relations": {
                    "platform": {
                        "directly_related_user_types": [{"type": "platform"}]
                    },
                    "owner": {"directly_related_user_types": [{"type": "user"}]},
                    "admin": {"directly_related_user_types": [{"type": "user"}]},
                    "viewer": {"directly_related_user_types": [{"type": "user"}]},
                    "member": {
                        "directly_related_user_types": [{"type": "user"}]
                    },
                }
            },
        },
        {
            "type": "libcloud_api",
            "relations": {
                "parent": {"this": {}},
                "platform": {"this": {}},
                "can_connect": {
                    "union": {
                        "child": [
                            {"this": {}},
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "parent"},
                                    "computedUserset": {"relation": "member"},
                                }
                            },
                            # SuperAdmin connects to the API gateway for global
                            # read-only visibility (rbac_design.md:32-34).
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "platform"},
                                    "computedUserset": {"relation": "global_reader"},
                                }
                            },
                        ]
                    }
                },
            },
            "metadata": {
                "relations": {
                    "parent": {"directly_related_user_types": [{"type": "tenant"}]},
                    "platform": {
                        "directly_related_user_types": [{"type": "platform"}]
                    },
                    "can_connect": {
                        "directly_related_user_types": [{"type": "user"}]
                    },
                }
            },
        },
        {
            "type": "provider",
            "relations": {
                "parent": {"this": {}},
                "platform": {"this": {}},
                "can_use": {
                    "union": {
                        "child": [
                            {"this": {}},
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "parent"},
                                    "computedUserset": {"relation": "member"},
                                }
                            },
                            # SuperAdmin may use every provider for read-only
                            # visibility. This does NOT grant can_provision on
                            # backends, because can_provision additionally
                            # requires a tenant role (owner/admin) via the
                            # intersection on each backend.
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "platform"},
                                    "computedUserset": {"relation": "global_reader"},
                                }
                            },
                        ]
                    }
                },
            },
            "metadata": {
                "relations": {
                    "parent": {"directly_related_user_types": [{"type": "tenant"}]},
                    "platform": {
                        "directly_related_user_types": [{"type": "platform"}]
                    },
                    "can_use": {
                        "directly_related_user_types": [{"type": "user"}]
                    },
                }
            },
        },
        {
            "type": "resource_class",
            "relations": {
                # A resource_class object is a (tenant, class) pair, e.g.
                # resource_class:aws-compute or resource_class:nutanix-network.
                # It is the first-class scope for per-class Admin/Viewer
                # sub-roles (rbac_design.md:7-15, 63-114).
                "tenant": {"this": {}},
                "platform": {"this": {}},
                "admin": {"this": {}},
                "viewer": {"this": {}},
                "tenant_admin": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "tenant"},
                        "computedUserset": {"relation": "admin"},
                    }
                },
                "tenant_owner": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "tenant"},
                        "computedUserset": {"relation": "owner"},
                    }
                },
                "tenant_viewer": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "tenant"},
                        "computedUserset": {"relation": "viewer"},
                    }
                },
                # A per-class Admin (direct `admin` grant on this object) OR a
                # tenant-wide Owner/Admin can provision within this class. This
                # is the relation that backends intersect/union with can_use to
                # express "Compute Admin but not Network Admin".
                "can_provision": {
                    "union": {
                        "child": [
                            {"computedUserset": {"relation": "admin"}},
                            {"computedUserset": {"relation": "tenant_admin"}},
                            {"computedUserset": {"relation": "tenant_owner"}},
                        ]
                    }
                },
                # Per-class update (edit) — mirrors can_provision so a per-class
                # Admin, a tenant Admin, or a tenant Owner can update within this
                # class (rbac_design.md changelog #10).
                "can_update": {
                    "union": {
                        "child": [
                            {"computedUserset": {"relation": "admin"}},
                            {"computedUserset": {"relation": "tenant_admin"}},
                            {"computedUserset": {"relation": "tenant_owner"}},
                        ]
                    }
                },
                "can_read": {
                    "union": {
                        "child": [
                            {"computedUserset": {"relation": "viewer"}},
                            {"computedUserset": {"relation": "tenant_viewer"}},
                            {"computedUserset": {"relation": "admin"}},
                            {"computedUserset": {"relation": "tenant_admin"}},
                            {"computedUserset": {"relation": "tenant_owner"}},
                            # SuperAdmin global read-only visibility.
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "platform"},
                                    "computedUserset": {"relation": "global_reader"},
                                }
                            },
                        ]
                    }
                },
            },
            "metadata": {
                "relations": {
                    "tenant": {
                        "directly_related_user_types": [{"type": "tenant"}]
                    },
                    "platform": {
                        "directly_related_user_types": [{"type": "platform"}]
                    },
                    "admin": {"directly_related_user_types": [{"type": "user"}]},
                    "viewer": {"directly_related_user_types": [{"type": "user"}]},
                }
            },
        },
        {
            "type": "aws_region",
            "relations": {
                "provider": {"this": {}},
                "tenant": {"this": {}},
                "platform": {"this": {}},
                "resource_class": {"this": {}},
                "tenant_admin": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "tenant"},
                        "computedUserset": {"relation": "admin"},
                    }
                },
                "tenant_owner": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "tenant"},
                        "computedUserset": {"relation": "owner"},
                    }
                },
                "tenant_viewer": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "tenant"},
                        "computedUserset": {"relation": "viewer"},
                    }
                },
                "can_read": {
                    "union": {
                        "child": [
                            {"computedUserset": {"relation": "tenant_viewer"}},
                            {"computedUserset": {"relation": "tenant_admin"}},
                            {"computedUserset": {"relation": "tenant_owner"}},
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "provider"},
                                    "computedUserset": {"relation": "can_use"},
                                }
                            },
                            # Per-class Viewer bindings (resource_class.can_read).
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "resource_class"},
                                    "computedUserset": {"relation": "can_read"},
                                }
                            },
                            # SuperAdmin global read-only visibility.
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "platform"},
                                    "computedUserset": {"relation": "global_reader"},
                                }
                            },
                        ]
                    }
                },
                "can_provision": {
                    "union": {
                        "child": [
                            # Tenant-wide Owner/Admin, gated by the provider
                            # can_use intersection for cross-cloud isolation.
                            {
                                "intersection": {
                                    "child": [
                                        {
                                            "union": {
                                                "child": [
                                                    {
                                                        "computedUserset": {
                                                            "relation": "tenant_admin"
                                                        }
                                                    },
                                                    {
                                                        "computedUserset": {
                                                            "relation": "tenant_owner"
                                                        }
                                                    },
                                                ]
                                            }
                                        },
                                        {
                                            "tupleToUserset": {
                                                "tupleset": {"relation": "provider"},
                                                "computedUserset": {
                                                    "relation": "can_use"
                                                },
                                            }
                                        },
                                    ]
                                }
                            },
                            # Per-class Admin bindings (resource_class.can_provision).
                            # The resource_class is itself tenant-scoped, so this
                            # arm cannot escape the tenant boundary.
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "resource_class"},
                                    "computedUserset": {"relation": "can_provision"},
                                }
                            },
                        ]
                    }
                },
                # Update (edit) on the backend — mirrors can_provision: tenant
                # Owner/Admin gated by the provider can_use intersection
                # for cross-cloud isolation, OR a per-class Admin via the bound
                # resource_class's can_update (rbac_design.md changelog #10).
                "can_update": {
                    "union": {
                        "child": [
                            {
                                "intersection": {
                                    "child": [
                                        {
                                            "union": {
                                                "child": [
                                                    {
                                                        "computedUserset": {
                                                            "relation": "tenant_admin"
                                                        }
                                                    },
                                                    {
                                                        "computedUserset": {
                                                            "relation": "tenant_owner"
                                                        }
                                                    },
                                                ]
                                            }
                                        },
                                        {
                                            "tupleToUserset": {
                                                "tupleset": {"relation": "provider"},
                                                "computedUserset": {
                                                    "relation": "can_use"
                                                },
                                            }
                                        },
                                    ]
                                }
                            },
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "resource_class"},
                                    "computedUserset": {"relation": "can_update"},
                                }
                            },
                        ]
                    }
                },
            },
            "metadata": {
                "relations": {
                    "provider": {
                        "directly_related_user_types": [{"type": "provider"}]
                    },
                    "tenant": {
                        "directly_related_user_types": [{"type": "tenant"}]
                    },
                    "platform": {
                        "directly_related_user_types": [{"type": "platform"}]
                    },
                    "resource_class": {
                        "directly_related_user_types": [{"type": "resource_class"}]
                    }
                }
            },
        },
        {
            "type": "nutanix_cluster",
            "relations": {
                "provider": {"this": {}},
                "tenant": {"this": {}},
                "platform": {"this": {}},
                "resource_class": {"this": {}},
                "tenant_admin": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "tenant"},
                        "computedUserset": {"relation": "admin"},
                    }
                },
                "tenant_owner": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "tenant"},
                        "computedUserset": {"relation": "owner"},
                    }
                },
                "tenant_viewer": {
                    "tupleToUserset": {
                        "tupleset": {"relation": "tenant"},
                        "computedUserset": {"relation": "viewer"},
                    }
                },
                "can_read": {
                    "union": {
                        "child": [
                            {"computedUserset": {"relation": "tenant_viewer"}},
                            {"computedUserset": {"relation": "tenant_admin"}},
                            {"computedUserset": {"relation": "tenant_owner"}},
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "provider"},
                                    "computedUserset": {"relation": "can_use"},
                                }
                            },
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "resource_class"},
                                    "computedUserset": {"relation": "can_read"},
                                }
                            },
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "platform"},
                                    "computedUserset": {"relation": "global_reader"},
                                }
                            },
                        ]
                    }
                },
                "can_provision": {
                    "union": {
                        "child": [
                            {
                                "intersection": {
                                    "child": [
                                        {
                                            "union": {
                                                "child": [
                                                    {
                                                        "computedUserset": {
                                                            "relation": "tenant_admin"
                                                        }
                                                    },
                                                    {
                                                        "computedUserset": {
                                                            "relation": "tenant_owner"
                                                        }
                                                    },
                                                ]
                                            }
                                        },
                                        {
                                            "tupleToUserset": {
                                                "tupleset": {"relation": "provider"},
                                                "computedUserset": {
                                                    "relation": "can_use"
                                                },
                                            }
                                        },
                                    ]
                                }
                            },
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "resource_class"},
                                    "computedUserset": {"relation": "can_provision"},
                                }
                            },
                        ]
                    }
                },
                # Update (edit) on the backend — mirrors can_provision: tenant
                # Owner/Admin gated by the provider can_use intersection
                # for cross-cloud isolation, OR a per-class Admin via the bound
                # resource_class's can_update (rbac_design.md changelog #10).
                "can_update": {
                    "union": {
                        "child": [
                            {
                                "intersection": {
                                    "child": [
                                        {
                                            "union": {
                                                "child": [
                                                    {
                                                        "computedUserset": {
                                                            "relation": "tenant_admin"
                                                        }
                                                    },
                                                    {
                                                        "computedUserset": {
                                                            "relation": "tenant_owner"
                                                        }
                                                    },
                                                ]
                                            }
                                        },
                                        {
                                            "tupleToUserset": {
                                                "tupleset": {"relation": "provider"},
                                                "computedUserset": {
                                                    "relation": "can_use"
                                                },
                                            }
                                        },
                                    ]
                                }
                            },
                            {
                                "tupleToUserset": {
                                    "tupleset": {"relation": "resource_class"},
                                    "computedUserset": {"relation": "can_update"},
                                }
                            },
                        ]
                    }
                },
            },
            "metadata": {
                "relations": {
                    "provider": {
                        "directly_related_user_types": [{"type": "provider"}]
                    },
                    "tenant": {
                        "directly_related_user_types": [{"type": "tenant"}]
                    },
                    "platform": {
                        "directly_related_user_types": [{"type": "platform"}]
                    },
                    "resource_class": {
                        "directly_related_user_types": [{"type": "resource_class"}]
                    }
                }
            },
        },
    ],
}

# Initial relationship tuples to seed.
#
# Principals (LLDAP users created by setup.sh):
#   superadmin    platform superadmin + owner on both tenants (break-glass)
#   aws-owner     owner  on tenant:aws
#   aws-admin     admin  on tenant:aws   -> can provision AWS
#   aws-viewer    viewer on tenant:aws   -> enumerate AWS only
#   ntnx-owner    owner  on tenant:nutanix
#   ntnx-admin    admin  on tenant:nutanix -> can provision Nutanix
#   ntnx-viewer   viewer on tenant:nutanix -> enumerate Nutanix only
#   cloud-denied  authenticated in Dex but NO tuples -> denied everywhere
#
# Per-class demo principals (OpenFGA-only, used to validate the resource_class
# surface; not backed by LLDAP/Dex logins):
#   aws-compute-admin   admin  on resource_class:aws-compute  -> provision AWS compute only
#   ntnx-compute-viewer viewer on resource_class:nutanix-compute -> read Nutanix compute only
INITIAL_TUPLES: List[Dict[str, str]] = [
    # Platform superadmin (bootstrap identity). SuperAdmin is NO LONGER seeded
    # as an owner on any tenant (rbac_design.md:40, 124). It instead gets global
    # read-only visibility via platform.global_reader, and gates owner
    # assignment + tenant lifecycle + global policy via the platform relations
    # below. To provision inside a tenant it must be explicitly granted that
    # tenant's owner/admin role (break-glass).
    {"user": "user:superadmin", "relation": "superadmin", "object": "platform:main"},
    # platform:main parents every tenant / api / provider / backend /
    # resource_class so the SuperAdmin-gated relations (global_reader,
    # can_manage_platform -> can_assign_owner) can resolve onto them.
    {"user": "platform:main", "relation": "platform", "object": "tenant:aws"},
    {"user": "platform:main", "relation": "platform", "object": "tenant:nutanix"},
    {"user": "platform:main", "relation": "platform", "object": "libcloud_api:main"},
    {"user": "platform:main", "relation": "platform", "object": "provider:aws"},
    {"user": "platform:main", "relation": "platform", "object": "provider:nutanix"},
    {"user": "platform:main", "relation": "platform", "object": "aws_region:aws"},
    {"user": "platform:main", "relation": "platform", "object": "nutanix_cluster:nutanix"},
    # tenant:aws membership
    {"user": "user:aws-owner", "relation": "owner", "object": "tenant:aws"},
    {"user": "user:aws-admin", "relation": "admin", "object": "tenant:aws"},
    {"user": "user:aws-viewer", "relation": "viewer", "object": "tenant:aws"},
    # tenant:nutanix membership
    {"user": "user:ntnx-owner", "relation": "owner", "object": "tenant:nutanix"},
    {"user": "user:ntnx-admin", "relation": "admin", "object": "tenant:nutanix"},
    {"user": "user:ntnx-viewer", "relation": "viewer", "object": "tenant:nutanix"},
    # libcloud REST API binding (both tenants parent the API gateway)
    {"user": "tenant:aws", "relation": "parent", "object": "libcloud_api:main"},
    {"user": "tenant:nutanix", "relation": "parent", "object": "libcloud_api:main"},
    # Providers under their tenants
    {"user": "tenant:aws", "relation": "parent", "object": "provider:aws"},
    {"user": "tenant:nutanix", "relation": "parent", "object": "provider:nutanix"},
    # Backends under providers + tenants (tenant relation drives role propagation).
    # The backend object id IS the tenant binding, so each tenant gets its own
    # isolated backend object (aws_region:aws, aws_region:aws-dev, ...) mapped
    # to its own Vault secret at secret/libcloud/<binding>. libcloud REST must
    # derive the backend object from connection.auth_binding to enforce this
    # end-to-end (see authorization.md §6).
    {"user": "provider:aws", "relation": "provider", "object": "aws_region:aws"},
    {"user": "tenant:aws", "relation": "tenant", "object": "aws_region:aws"},
    {"user": "provider:nutanix", "relation": "provider", "object": "nutanix_cluster:nutanix"},
    {"user": "tenant:nutanix", "relation": "tenant", "object": "nutanix_cluster:nutanix"},
    # Resource classes (rbac_design.md:7-15). Each is a (tenant, class) pair.
    # platform:main parents each so SuperAdmin global_reader can read them.
    {"user": "tenant:aws", "relation": "tenant", "object": "resource_class:aws-compute"},
    {"user": "platform:main", "relation": "platform", "object": "resource_class:aws-compute"},
    {"user": "tenant:aws", "relation": "tenant", "object": "resource_class:aws-network"},
    {"user": "platform:main", "relation": "platform", "object": "resource_class:aws-network"},
    {"user": "tenant:aws", "relation": "tenant", "object": "resource_class:aws-data"},
    {"user": "platform:main", "relation": "platform", "object": "resource_class:aws-data"},
    {"user": "tenant:aws", "relation": "tenant", "object": "resource_class:aws-platform"},
    {"user": "platform:main", "relation": "platform", "object": "resource_class:aws-platform"},
    {"user": "tenant:nutanix", "relation": "tenant", "object": "resource_class:nutanix-compute"},
    {"user": "platform:main", "relation": "platform", "object": "resource_class:nutanix-compute"},
    {"user": "tenant:nutanix", "relation": "tenant", "object": "resource_class:nutanix-network"},
    {"user": "platform:main", "relation": "platform", "object": "resource_class:nutanix-network"},
    {"user": "tenant:nutanix", "relation": "tenant", "object": "resource_class:nutanix-data"},
    {"user": "platform:main", "relation": "platform", "object": "resource_class:nutanix-data"},
    {"user": "tenant:nutanix", "relation": "tenant", "object": "resource_class:nutanix-platform"},
    {"user": "platform:main", "relation": "platform", "object": "resource_class:nutanix-platform"},
    # Bind each backend to its tenant's resource classes. A per-class Admin on
    # any bound class gains can_provision on the backend; a per-class Viewer
    # gains can_read. (With a single backend per cloud this demonstrates the
    # wiring; per-class isolation becomes observable once separate backends
    # exist per class.)
    {"user": "resource_class:aws-compute", "relation": "resource_class", "object": "aws_region:aws"},
    {"user": "resource_class:aws-network", "relation": "resource_class", "object": "aws_region:aws"},
    {"user": "resource_class:aws-data", "relation": "resource_class", "object": "aws_region:aws"},
    {"user": "resource_class:aws-platform", "relation": "resource_class", "object": "aws_region:aws"},
    {"user": "resource_class:nutanix-compute", "relation": "resource_class", "object": "nutanix_cluster:nutanix"},
    {"user": "resource_class:nutanix-network", "relation": "resource_class", "object": "nutanix_cluster:nutanix"},
    {"user": "resource_class:nutanix-data", "relation": "resource_class", "object": "nutanix_cluster:nutanix"},
    {"user": "resource_class:nutanix-platform", "relation": "resource_class", "object": "nutanix_cluster:nutanix"},
    # Per-class demo bindings (OpenFGA-only validation principals).
    {"user": "user:aws-compute-admin", "relation": "admin", "object": "resource_class:aws-compute"},
    {"user": "user:ntnx-compute-viewer", "relation": "viewer", "object": "resource_class:nutanix-compute"},
]

# Validation expectations: (user, relation, object, expected_allowed)
VALIDATION_CHECKS: List[Tuple[str, str, str, bool]] = [
    # Platform superadmin: global governance + global read-only visibility,
    # but NO provisioning inside any tenant by default (rbac_design.md:124).
    ("user:superadmin", "can_manage_platform", "platform:main", True),
    ("user:superadmin", "can_manage_tenant_lifecycle", "platform:main", True),
    ("user:superadmin", "can_manage_global_policy", "platform:main", True),
    ("user:superadmin", "can_manage_iam_mapping", "platform:main", True),
    ("user:superadmin", "can_connect", "libcloud_api:main", True),
    ("user:superadmin", "can_use", "provider:aws", True),
    ("user:superadmin", "can_use", "provider:nutanix", True),
    ("user:superadmin", "can_read", "tenant:aws", True),
    ("user:superadmin", "can_read", "tenant:nutanix", True),
    ("user:superadmin", "can_read", "aws_region:aws", True),
    ("user:superadmin", "can_read", "nutanix_cluster:nutanix", True),
    ("user:superadmin", "can_read", "resource_class:aws-compute", True),
    ("user:superadmin", "can_provision", "aws_region:aws", False),
    ("user:superadmin", "can_provision", "nutanix_cluster:nutanix", False),
    # SuperAdmin gates owner assignment on every tenant; tenant Owners do not.
    ("user:superadmin", "can_assign_owner", "tenant:aws", True),
    ("user:superadmin", "can_assign_owner", "tenant:nutanix", True),
    ("user:aws-owner", "can_assign_owner", "tenant:aws", False),
    # tenant:aws — owner
    ("user:aws-owner", "can_connect", "libcloud_api:main", True),
    ("user:aws-owner", "can_use", "provider:aws", True),
    ("user:aws-owner", "can_provision", "aws_region:aws", True),
    ("user:aws-owner", "can_assign_admin", "tenant:aws", True),
    ("user:aws-owner", "can_assign_viewer", "tenant:aws", True),
    # tenant:aws — admin (provision, but NO membership changes at all)
    ("user:aws-admin", "can_use", "provider:aws", True),
    ("user:aws-admin", "can_provision", "aws_region:aws", True),
    ("user:aws-admin", "can_assign_admin", "tenant:aws", False),
    ("user:aws-admin", "can_assign_owner", "tenant:aws", False),
    ("user:aws-admin", "can_assign_viewer", "tenant:aws", False),
    # Credential management is owner-only (admins/viewers/superadmin-by-default
    # cannot update creds; superadmin must be explicitly granted owner for
    # break-glass).
    ("user:aws-owner", "can_manage_credentials", "tenant:aws", True),
    ("user:aws-admin", "can_manage_credentials", "tenant:aws", False),
    ("user:aws-viewer", "can_manage_credentials", "tenant:aws", False),
    ("user:ntnx-owner", "can_manage_credentials", "tenant:nutanix", True),
    ("user:ntnx-admin", "can_manage_credentials", "tenant:nutanix", False),
    ("user:superadmin", "can_manage_credentials", "tenant:aws", False),
    ("user:superadmin", "can_manage_credentials", "tenant:nutanix", False),
    ("user:aws-owner", "can_manage_credentials", "tenant:nutanix", False),
    # tenant:aws — viewer (enumerate only)
    ("user:aws-viewer", "can_use", "provider:aws", True),
    ("user:aws-viewer", "can_provision", "aws_region:aws", False),
    ("user:aws-viewer", "can_read", "aws_region:aws", True),
    ("user:aws-viewer", "can_assign_viewer", "tenant:aws", False),
    # Cross-cloud isolation: aws-admin cannot use/provision Nutanix
    ("user:aws-admin", "can_use", "provider:nutanix", False),
    ("user:aws-admin", "can_provision", "nutanix_cluster:nutanix", False),
    # can_update (edit): Owner + Admin can update; Viewer and SuperAdmin (by
    # default) cannot. Per-class Admin can update on the bound backend.
    ("user:aws-owner", "can_update", "tenant:aws", True),
    ("user:aws-admin", "can_update", "tenant:aws", True),
    ("user:aws-viewer", "can_update", "tenant:aws", False),
    ("user:aws-owner", "can_update", "aws_region:aws", True),
    ("user:aws-admin", "can_update", "aws_region:aws", True),
    ("user:aws-viewer", "can_update", "aws_region:aws", False),
    ("user:superadmin", "can_update", "aws_region:aws", False),
    ("user:aws-admin", "can_update", "nutanix_cluster:nutanix", False),
    ("user:aws-compute-admin", "can_update", "aws_region:aws", True),
    ("user:ntnx-compute-viewer", "can_update", "nutanix_cluster:nutanix", False),
    # tenant:nutanix — admin / viewer
    ("user:ntnx-admin", "can_use", "provider:nutanix", True),
    ("user:ntnx-admin", "can_provision", "nutanix_cluster:nutanix", True),
    ("user:ntnx-viewer", "can_provision", "nutanix_cluster:nutanix", False),
    ("user:ntnx-viewer", "can_read", "nutanix_cluster:nutanix", True),
    # Per-class Admin (resource_class): can provision + read on the bound
    # backend, but is NOT a tenant member, so cannot can_connect / can_use /
    # provision a different cloud's backend.
    ("user:aws-compute-admin", "can_provision", "aws_region:aws", True),
    ("user:aws-compute-admin", "can_read", "aws_region:aws", True),
    ("user:aws-compute-admin", "can_use", "provider:aws", False),
    ("user:aws-compute-admin", "can_connect", "libcloud_api:main", False),
    ("user:aws-compute-admin", "can_provision", "nutanix_cluster:nutanix", False),
    # Per-class Viewer (resource_class): read only on the bound backend, no
    # provisioning, no cross-cloud reach.
    ("user:ntnx-compute-viewer", "can_read", "nutanix_cluster:nutanix", True),
    ("user:ntnx-compute-viewer", "can_provision", "nutanix_cluster:nutanix", False),
    ("user:ntnx-compute-viewer", "can_provision", "aws_region:aws", False),
    # Authenticated-but-unauthorized demo user is denied at the gate
    ("user:cloud-denied", "can_connect", "libcloud_api:main", False),
]


# --------------------------------------------------------------------------- #
# Bootstrap orchestration
# --------------------------------------------------------------------------- #
@dataclass
class Bootstrapper:
    client: FgaClient
    store_name: str
    store_id: str = ""
    model_id: str = ""
    _normalized_model: Dict[str, Any] = field(default_factory=dict)

    # -- Store -------------------------------------------------------------- #
    def ensure_store(self) -> str:
        """Create the store, or reuse an existing one with the same name."""
        existing = self._find_store_by_name(self.store_name)
        if existing:
            self.store_id = existing["id"]
            log.info("Reusing existing store '%s' (id=%s)", self.store_name, self.store_id)
            return self.store_id

        log.info("Creating store '%s' ...", self.store_name)
        resp = self.client.post("/stores", {"name": self.store_name})
        self.store_id = resp["id"]
        log.info("Created store id=%s", self.store_id)
        return self.store_id

    def _find_store_by_name(self, name: str) -> Optional[Dict[str, Any]]:
        token = ""
        while True:
            path = "/stores?page_size=100"
            if token:
                path += f"&continuation_token={token}"
            resp = self.client.get(path)
            for store in resp.get("stores", []):
                if store.get("name") == name:
                    return store
            token = resp.get("continuation_token") or ""
            if not token:
                return None

    # -- Authorization model ------------------------------------------------ #
    def ensure_model(self) -> str:
        """
        Register the sample model unless the latest model is already identical.
        Idempotency is based on a structural comparison of type_definitions +
        schema_version (server-assigned 'id' fields are ignored).
        """
        self._normalized_model = self._normalize_model(LIBCLOUD_MODEL)
        latest = self._latest_model()
        if latest and self._normalize_model(latest) == self._normalized_model:
            self.model_id = latest["id"]
            log.info("Latest authorization model already matches (id=%s) — skipping write",
                     self.model_id)
            return self.model_id

        log.info("Writing new authorization model ...")
        resp = self.client.post(
            f"/stores/{self.store_id}/authorization-models", LIBCLOUD_MODEL
        )
        self.model_id = resp["authorization_model_id"]
        log.info("Wrote authorization model id=%s", self.model_id)
        return self.model_id

    def _latest_model(self) -> Optional[Dict[str, Any]]:
        resp = self.client.get(
            f"/stores/{self.store_id}/authorization-models?page_size=1"
        )
        models = resp.get("authorization_models", [])
        return models[0] if models else None

    @classmethod
    def _normalize_model(cls, model: Dict[str, Any]) -> str:
        """
        Produce a canonical string for structural comparison.

        The server expands models on read by injecting default/empty fields
        (e.g. relations={}, metadata=null, condition="", module="",
        source_info=null, object="") and the server-assigned 'id'. We strip all
        empty/default noise recursively so a model we *send* compares equal to
        the same model *read back* from the server.
        """
        stripped = cls._strip_empties(
            {
                "schema_version": model.get("schema_version"),
                "type_definitions": model.get("type_definitions", []),
            }
        )
        return json.dumps(stripped, sort_keys=True, separators=(",", ":"))

    # Keys the server fills with empty defaults; drop them when empty.
    _NOISE_KEYS = {"id", "module", "source_info", "condition", "object"}

    @classmethod
    def _strip_empties(cls, value: Any) -> Any:
        """Recursively remove empty/null/default fields for stable comparison."""
        if isinstance(value, dict):
            out: Dict[str, Any] = {}
            for k, v in value.items():
                cleaned = cls._strip_empties(v)
                # Drop None, empty dict/list/string outright.
                if cleaned in (None, {}, [], ""):
                    continue
                # Drop known noise keys regardless (they only carry defaults).
                if k in cls._NOISE_KEYS and cleaned in (None, "", {}, []):
                    continue
                out[k] = cleaned
            return out
        if isinstance(value, list):
            return [cls._strip_empties(v) for v in value]
        return value

    # -- Tuples ------------------------------------------------------------- #
    def ensure_tuples(self) -> None:
        """Write seed tuples that are not already present (idempotent)."""
        existing = self._read_all_tuples()
        existing_keys = {
            (t["key"]["user"], t["key"]["relation"], t["key"]["object"])
            for t in existing
        }

        to_write = []
        seen = set()
        for tup in INITIAL_TUPLES:
            key = (tup["user"], tup["relation"], tup["object"])
            if key in existing_keys or key in seen:
                continue
            seen.add(key)
            to_write.append(tup)

        if not to_write:
            log.info("All %d seed tuples already present — nothing to write",
                     len(INITIAL_TUPLES))
            return

        log.info("Writing %d new tuple(s) (skipping %d already present) ...",
                 len(to_write), len(INITIAL_TUPLES) - len(to_write))

        # OpenFGA Write accepts up to 100 tuples per request; batch defensively.
        for batch in _chunks(to_write, 100):
            payload = {
                "authorization_model_id": self.model_id,
                "writes": {"tuple_keys": batch},
            }
            try:
                self.client.post(f"/stores/{self.store_id}/write", payload)
            except FgaHttpError as e:
                # 400 with "already exists" can happen under concurrent runs.
                if e.status == 400 and "already exists" in e.body.lower():
                    log.warning("Some tuples already existed during write — continuing")
                else:
                    raise
        log.info("Tuple write complete")

    def _read_all_tuples(self) -> List[Dict[str, Any]]:
        tuples: List[Dict[str, Any]] = []
        token = ""
        while True:
            payload: Dict[str, Any] = {"page_size": 100}
            if token:
                payload["continuation_token"] = token
            resp = self.client.post(f"/stores/{self.store_id}/read", payload)
            tuples.extend(resp.get("tuples", []))
            token = resp.get("continuation_token") or ""
            if not token:
                break
        return tuples

    # -- Validation --------------------------------------------------------- #
    def validate(self, max_attempts: int = 6, backoff_base: float = 0.5) -> None:
        """
        Run Check() for each expectation. Retries the *whole* set with backoff
        to tolerate write propagation / eventual consistency, then fails hard
        if any expectation is still wrong.
        """
        log.info("Validating deployment with %d check(s) ...", len(VALIDATION_CHECKS))
        for attempt in range(1, max_attempts + 1):
            failures: List[str] = []
            for user, relation, obj, expected in VALIDATION_CHECKS:
                allowed = self._check(user, relation, obj)
                status = "OK" if allowed == expected else "MISMATCH"
                log.debug("  check %s %s %s -> allowed=%s expected=%s [%s]",
                          user, relation, obj, allowed, expected, status)
                if allowed != expected:
                    failures.append(
                        f"{user} {relation} {obj}: got {allowed}, expected {expected}"
                    )

            if not failures:
                log.info("✅ All %d validation checks passed", len(VALIDATION_CHECKS))
                return

            if attempt < max_attempts:
                delay = backoff_base * (2 ** (attempt - 1))
                log.warning(
                    "%d/%d checks failing (attempt %d/%d) — retrying in %.1fs",
                    len(failures), len(VALIDATION_CHECKS), attempt, max_attempts, delay,
                )
                time.sleep(delay)
            else:
                for f in failures:
                    log.error("  validation failure: %s", f)
                raise FgaValidationError(
                    f"{len(failures)} validation check(s) failed after {max_attempts} attempts"
                )

    def _check(self, user: str, relation: str, obj: str) -> bool:
        payload = {
            "authorization_model_id": self.model_id,
            "tuple_key": {"user": user, "relation": relation, "object": obj},
        }
        resp = self.client.post(f"/stores/{self.store_id}/check", payload)
        return bool(resp.get("allowed", False))

    # -- Driver ------------------------------------------------------------- #
    def run(self) -> Dict[str, str]:
        self.ensure_store()
        self.ensure_model()
        self.ensure_tuples()
        self.validate()
        log.info("Bootstrap complete — store_id=%s model_id=%s",
                 self.store_id, self.model_id)
        return {"store_id": self.store_id, "model_id": self.model_id}


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def _chunks(seq: List[Any], n: int):
    for i in range(0, len(seq), n):
        yield seq[i : i + n]


def main() -> int:
    # Gate: only superadmin may change OpenFGA policy / privilege tuples.
    # setup.sh obtains SUPERADMIN_JWT via scripts/superadmin_auth.sh and passes
    # it through the compose environment. Direct invocations without it fail.
    if not os.environ.get("SUPERADMIN_JWT", "").strip():
        log.error(
            "SUPERADMIN_JWT is not set. OpenFGA policy / privilege changes are "
            "gated on a successful Dex login as the LLDAP `superadmin` user. "
            "Run ./scripts/superadmin_auth.sh first (or ./setup.sh) and export "
            "SUPERADMIN_JWT."
        )
        return 3
    base_url = os.environ.get("FGA_API_URL", "http://localhost:8080")
    # OpenFGA runs with OIDC authn: forward the superadmin Dex JWT as the
    # Bearer token (it has aud=libcloud-rest, which OpenFGA accepts). An
    # explicit FGA_API_TOKEN still wins (e.g. for preshared-key mode).
    token = os.environ.get("FGA_API_TOKEN") or os.environ.get("SUPERADMIN_JWT") or None
    store_name = os.environ.get("FGA_STORE_NAME", "libcloud-rest-store")

    log.info("OpenFGA bootstrap targeting %s (store='%s')", base_url, store_name)
    client = FgaClient(base_url=base_url, token=token)
    boot = Bootstrapper(client=client, store_name=store_name)

    try:
        result = boot.run()
    except FgaValidationError as e:
        log.error("Validation failed: %s", e)
        return 2
    except FgaHttpError as e:
        log.error("API error (HTTP %s): %s", e.status, e.body)
        return 1
    except FgaError as e:
        log.error("Bootstrap error: %s", e)
        return 1

    out_dir = os.environ.get("FGA_OUTPUT_DIR", "generated")
    public_url = os.environ.get("FGA_PUBLIC_API_URL", base_url)
    os.makedirs(out_dir, exist_ok=True)
    env_path = os.path.join(out_dir, "fga.env")
    with open(env_path, "w", encoding="utf-8") as fh:
        fh.write(f"FGA_STORE_ID={result['store_id']}\n")
        fh.write(f"FGA_MODEL_ID={result['model_id']}\n")
        fh.write(f"FGA_API_URL={public_url.rstrip('/')}\n")
        fh.write(f"FGA_STORE_NAME={store_name}\n")
    log.info("Wrote %s", env_path)

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
