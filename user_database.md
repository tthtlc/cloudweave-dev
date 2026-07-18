
LLDAP users provisioned by setup.sh (passwords known)

  These are the users you can sign in with via the portal's Sign in with LLDAP button (or idp_login.py):

  ┌──────────────┬─────────────────────────────┬─────────────────────────────┬─────────────────────────────────────────────────┐
  │ uid (login)  │ password                    │ email                       │ role (OpenFGA)                                  │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ superadmin   │ SA-KaiJKLDfuB3kLx0isMrBF7zD │ superadmin@libcloud.local   │ superadmin (platform owner)                     │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ aws-owner    │ SA-lxGstsywP-b4-O8HVW6bCShe │ aws-owner@libcloud.local    │ owner of tenant:aws                             │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ aws-admin    │ SA-8dp2YSE6nCCB2Yt3X67QMMHS │ aws-admin@libcloud.local    │ admin of tenant:aws (can provision AWS)         │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ aws-viewer   │ SA-geRhMYjjLH4RZoEubQg7DqIW │ aws-viewer@libcloud.local   │ viewer of tenant:aws                            │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ ntnx-owner   │ SA-78nmx5Ws7ELlsPRaq6SPyaeM │ ntnx-owner@libcloud.local   │ owner of tenant:nutanix                         │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ ntnx-admin   │ SA-BxzWRoAnlpMt3j6XHyb966KJ │ ntnx-admin@libcloud.local   │ admin of tenant:nutanix (can provision Nutanix) │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ ntnx-viewer  │ SA-OrGaiGBjcvDb38fmBlvvQP-D │ ntnx-viewer@libcloud.local  │ viewer of tenant:nutanix                        │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ cloud-denied │ CloudDenied123!             │ cloud-denied@libcloud.local │ authenticated but denied                        │
  └──────────────┴─────────────────────────────┴─────────────────────────────┴─────────────────────────────────────────────────┘


  LLDAP users provisioned by setup.sh (passwords known)

  These are the users you can sign in with via the portal's Sign in with LLDAP button (or idp_login.py):

  ┌──────────────┬─────────────────────────────┬─────────────────────────────┬─────────────────────────────────────────────────┐
  │ uid (login)  │ password                    │ email                       │ role (OpenFGA)                                  │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ superadmin   │ SA-KaiJKLDfuB3kLx0isMrBF7zD │ superadmin@libcloud.local   │ superadmin (platform owner)                     │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ aws-owner    │ SA-lxGstsywP-b4-O8HVW6bCShe │ aws-owner@libcloud.local    │ owner of tenant:aws                             │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ aws-admin    │ SA-8dp2YSE6nCCB2Yt3X67QMMHS │ aws-admin@libcloud.local    │ admin of tenant:aws (can provision AWS)         │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ aws-viewer   │ SA-geRhMYjjLH4RZoEubQg7DqIW │ aws-viewer@libcloud.local   │ viewer of tenant:aws                            │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ ntnx-owner   │ SA-78nmx5Ws7ELlsPRaq6SPyaeM │ ntnx-owner@libcloud.local   │ owner of tenant:nutanix                         │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ ntnx-admin   │ SA-BxzWRoAnlpMt3j6XHyb966KJ │ ntnx-admin@libcloud.local   │ admin of tenant:nutanix (can provision Nutanix) │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ ntnx-viewer  │ SA-OrGaiGBjcvDb38fmBlvvQP-D │ ntnx-viewer@libcloud.local  │ viewer of tenant:nutanix                        │
  ├──────────────┼─────────────────────────────┼─────────────────────────────┼─────────────────────────────────────────────────┤
  │ cloud-denied │ CloudDenied123!             │ cloud-denied@libcloud.local │ authenticated but denied                        │
  └──────────────┴─────────────────────────────┴─────────────────────────────┴─────────────────────────────────────────────────┘

  The SA-… values are randomly generated by dex_bootstrap.py (_gen_password) on first run and persisted to dex/generated/dex.env. cloud-denied's password is
