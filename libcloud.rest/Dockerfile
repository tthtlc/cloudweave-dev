FROM python:3.12-slim

# Vendored Apache libcloud — pinned to v3.9.1.
#
# libcloud.rest does NOT pin libcloud via libcloud.rest/requirements.txt.
# Instead this image installs the vendored source tree at ./libcloud (a full
# git checkout of https://github.com/apache/libcloud.git) via `COPY libcloud
# /libcloud` + `pip install /libcloud` below. So the libcloud version the REST
# API runs against is exactly whatever commit ./libcloud is at.
#
# ./libcloud is pinned to the stable upstream release apache-libcloud v3.9.1
# (PyPI: https://pypi.org/project/apache-libcloud/3.9.1/), upstream commit
# 6c867a3ca299f1b16057fab96bff65564c0ac5fe (2026-04-16). setup.sh verifies this
# pin at build time (it fails fast if ./libcloud has drifted off the pinned
# commit), mirroring how openfga_postgres pins the OpenFGA tarball checksum.
#
# On top of v3.9.1 this repo carries a LOCAL Nutanix driver that is NOT upstream:
#   libcloud/common/nutanix.py
#   libcloud/compute/drivers/nutanix.py
#   libcloud/storage/drivers/nutanix.py
# plus its registration in libcloud/compute/types.py (Provider.NUTANIX) and
# libcloud/compute/providers.py (NutanixNodeDriver). These are the only diff
# against the v3.9.1 tag (3 lines) — see `git -C libcloud diff v3.9.1`.
#
# To upgrade libcloud: bump LIBCLOUD_PIN_TAG / LIBCLOUD_PIN_COMMIT in setup.sh,
# `cd libcloud && git checkout <new-tag>`, then re-apply the Nutanix registration
# (the 3 hunks in types.py / providers.py) and verify the Nutanix driver still
# imports against the new base.

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    USERS_FILE=data/users.json

# No apt-get / curl — the isolated build environment has no internet access.
# Use Python stdlib (urllib) for the healthcheck instead.

COPY libcloud.rest/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY libcloud /libcloud
RUN pip install --no-cache-dir /libcloud

COPY libcloud.rest/app ./app
COPY libcloud.rest/data ./data-seed
COPY libcloud.rest/docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh \
    && useradd --create-home --shell /usr/sbin/nologin appuser \
    && mkdir -p /app/data \
    && chown -R appuser:appuser /app

USER appuser

EXPOSE 8765

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8765/health')" || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8765"]
