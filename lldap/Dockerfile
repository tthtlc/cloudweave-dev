# lldap-tools: containerized LLDAP management tooling.
# Provides curl, jq, openssl and python3+ldap3 so that setup-schema.sh,
# create-user.sh, set-password.py and verify-ldap.py can run with zero host
# dependencies beyond Docker itself.
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl jq openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir ldap3

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh /scripts/*.py

WORKDIR /scripts
ENTRYPOINT []
