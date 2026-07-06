
025f2b8b53eb87003876e5ac3d6dc45d6d72ac6b02bdc6ed82c3507aa4247 0.0s done
    #17 exporting manifest list sha256:57ba7ba9f23aeb9b6a1f0d27f4d16a9e753af1ac3c1b8b8a64c8dde31e48621c 0.0s done
    #17 naming to docker.io/library/libcloud-rest-api:latest done
    #17 unpacking to docker.io/library/libcloud-rest-api:latest 0.1s done
    #17 DONE 0.3s
    #18 resolving provenance for metadata file
    #18 DONE 0.0s
     Image libcloud-rest-api:latest Built 
     Container libcloud-rest-api Recreate 
     Container libcloud-rest-api Recreated 
     Container libcloud-rest-api Starting 
     Container libcloud-rest-api Started 
    Setup complete.
      OpenFGA env  : /home/ubuntu/libcloud_nutanix/openfga_my/generated/fga.env
      Dex OIDC     : /home/ubuntu/libcloud_nutanix/openfga_my/../dex/generated/dex.env
      Vault        : /home/ubuntu/libcloud_nutanix/openfga_my/../vault/generated/vault.env
    Identity model:
      superadmin   / SA-ek5u00Jfr7x9wC_0Eon-2KDU   (bootstrap: Vault/OpenFGA/LLDAP admin)
      aws-owner    / SA-R4X97QIFWxUTanyURRs18iRR    (owner  of tenant:aws)
      aws-admin    / SA-BrBN14F0f6gat2TidYC6-IvT    (admin  of tenant:aws -> provision AWS)
      aws-viewer   / SA-NUEhzp0otBdhiWPmggW5cvr6   (viewer of tenant:aws -> enumerate only)
      ntnx-owner   / SA-o89IaXxgQh9IrsT0ApZ4n7nB   (owner  of tenant:nutanix)
      ntnx-admin   / SA-goLdHTrUKyCWT0Br6IbIIhl8   (admin  of tenant:nutanix -> provision Nutanix)
      ntnx-viewer  / SA-xSGnxs7vu8GyJwD8sYGqvDX8  (viewer of tenant:nutanix -> enumerate only)
      cloud-denied / CloudDenied123! (authenticated but denied)
    Cloud backend credentials are per-tenant and NOT set by setup.sh.
    Each tenant's OWNER writes its credentials to Vault (gated by OpenFGA
    can_manage_credentials; admins/viewers cannot):
      TENANT=aws LIBCLOUD_USER=aws-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_AWS_OWNER \
        LIBCLOUD_AWS_KEY=AKIA... LIBCLOUD_AWS_SECRET=... \
        python3 scripts/set_tenant_credentials.py
      TENANT=nutanix LIBCLOUD_USER=ntnx-owner LIBCLOUD_PASSWORD=$LIBCLOUD_PASSWORD_NTNX_OWNER \
        LIBCLOUD_NTNX_USER=admin LIBCLOUD_NTNX_PASSWORD=... \
        python3 scripts/set_tenant_credentials.py
    superadmin (owner on both tenants) can set them too.
    Then run:
      LIBCLOUD_USER=aws-admin   ./scripts/provision_aws.sh
      LIBCLOUD_USER=aws-viewer  ./scripts/provision_aws.sh
      LIBCLOUD_USER=ntnx-admin  ./scripts/provision_nutanix.sh
      LIBCLOUD_USER=ntnx-viewer ./scripts/provision_nutanix.sh
     ctrl+o to collapse

  Setup completed — all per-cloud users created in LLDAP and ../dex/generated/dex.env regenerated with their real passwords (aws-admin → SA-BrBN14F0f6gat2TidYC6-IvT). Let me verify the aws-admin login now works with a dry run (no PROVISION=1, so no real EC2 created).


