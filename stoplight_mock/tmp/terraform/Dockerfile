FROM hashicorp/terraform:1.9.8

# Download Nutanix provider v2.2.1
ARG PROVIDER_VERSION=2.2.1
ARG PROVIDER_ARCH=linux_amd64

RUN set -eux; \
    mkdir -p /tmp/provider; \
    cd /tmp/provider; \
    wget -q "https://github.com/nutanix/terraform-provider-nutanix/releases/download/v${PROVIDER_VERSION}/terraform-provider-nutanix_${PROVIDER_VERSION}_${PROVIDER_ARCH}.zip"; \
    unzip -q "terraform-provider-nutanix_${PROVIDER_VERSION}_${PROVIDER_ARCH}.zip"; \
    rm "terraform-provider-nutanix_${PROVIDER_VERSION}_${PROVIDER_ARCH}.zip"; \
    chmod +x terraform-provider-nutanix_v*; \
    ls -la

# Set up filesystem mirror layout
# Terraform expects: <mirror>/<hostname>/<namespace>/<type>/<version>/<target>/
RUN MIRROR_BASE="/terraform/providers/registry.terraform.io/nutanix/nutanix/${PROVIDER_VERSION}/linux_amd64"; \
    mkdir -p "$MIRROR_BASE"; \
    cp /tmp/provider/terraform-provider-nutanix_v* "$MIRROR_BASE/terraform-provider-nutanix_v${PROVIDER_VERSION}"; \
    rm -rf /tmp/provider

# Terraform CLI config — use filesystem mirror for Nutanix (avoids registry calls)
COPY terraform.rc /home/tfcache/.terraformrc

# Make directories writable by the terraform user (UID 1000)
RUN chown -R 1000:1000 /home/tfcache /terraform && \
    chmod -R 755 /home/tfcache /terraform

ENV TF_CLI_CONFIG_FILE=/home/tfcache/.terraformrc

VOLUME ["/workspace"]
WORKDIR /workspace

ENTRYPOINT ["terraform"]
