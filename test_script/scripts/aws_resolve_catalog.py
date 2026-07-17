#!/usr/bin/env python3
"""Pick a compatible AWS AMI and instance type for provisioning demos."""

from __future__ import annotations

import json
import os
import sys
from typing import Any

ARCH = os.environ.get("AWS_INSTANCE_ARCH", "x86_64")
PREFERRED_SIZE = os.environ.get("AWS_DEFAULT_SIZE_ID", "")

ARM_FAMILIES = {
    "a1",
    "c6g",
    "c6gd",
    "c6gn",
    "c7g",
    "c7gd",
    "c7gn",
    "c8g",
    "c8gd",
    "c8gn",
    "g5g",
    "hpc7g",
    "i4g",
    "im4gn",
    "is4gen",
    "m6g",
    "m6gd",
    "m7g",
    "m7gd",
    "m8g",
    "m8gd",
    "r6g",
    "r6gd",
    "r7g",
    "r7gd",
    "r8g",
    "r8gd",
    "t4g",
    "x2gd",
}

DEFAULT_SIZE_BY_ARCH = {
    "x86_64": "t3.micro",
    "arm64": "t4g.micro",
}

CANONICAL_OWNER_ID = "099720109477"

SKIP_NAME_TERMS = (
    "sql",
    "enterprise",
    "deep learning",
    "elasticsearch",
    "appgate",
    "laravel",
    "wordpress",
    "kibana",
    "gpu",
    "nvidia",
    "procomputers",
    "supportedimages",
)


def _name_blocked(name: str) -> bool:
    lowered = name.lower()
    return any(term in lowered for term in SKIP_NAME_TERMS)


def instance_arch(size_id: str, extra: dict[str, Any] | None = None) -> str:
    extra = extra or {}
    processor = str(extra.get("physicalProcessor", ""))
    if "Graviton" in processor:
        return "arm64"
    family = size_id.split(".", 1)[0]
    if family in ARM_FAMILIES:
        return "arm64"
    return "x86_64"


def score_image(image: dict[str, Any]) -> int:
    name = str(image.get("name", "")).lower()
    extra = image.get("extra") or {}
    score = 0
    if str(extra.get("owner_id")) == CANONICAL_OWNER_ID:
        score += 200
    if name.startswith("ubuntu/images/hvm-ssd-gp3/ubuntu-noble"):
        score += 150
    if name.startswith("ubuntu/images/hvm-ssd/ubuntu-jammy"):
        score += 140
    if "ubuntu/images/hvm-ssd" in name:
        score += 120
    if name.startswith("ubuntu/images"):
        score += 100
    if "ubuntu-server" in name:
        score += 40
    if "hvm" in name and "ssd" in name:
        score += 10
    if str(extra.get("owner_alias", "")) == "amazon":
        score += 5
    if "aws-marketplace" in str(extra.get("image_location", "")):
        score -= 50
    if "deep learning" in name or "elasticsearch" in name or "laravel" in name:
        score -= 40
    if "22.04 lts" in name or "ubuntu 22.04" in name:
        score += 30
    if "24.04 lts" in name or "ubuntu 24.04" in name:
        score += 25
    if len(name) > 80:
        score -= 20
    return score


def pick_image(images: list[dict[str, Any]], arch: str) -> str:
    candidates = [
        img
        for img in images
        if str((img.get("extra") or {}).get("architecture", "x86_64")) == arch
        and not _name_blocked(str(img.get("name", "")))
    ]
    if not candidates:
        candidates = [
            img
            for img in images
            if str((img.get("extra") or {}).get("architecture", "x86_64")) == arch
        ]
    if not candidates:
        return ""
    candidates.sort(key=score_image, reverse=True)
    return str(candidates[0]["id"])


def pick_size(sizes: list[dict[str, Any]], arch: str) -> str:
    preferred = PREFERRED_SIZE or DEFAULT_SIZE_BY_ARCH.get(arch, "t3.micro")
    by_id = {str(size["id"]): size for size in sizes}
    if preferred in by_id and instance_arch(preferred, by_id[preferred].get("extra")) == arch:
        return preferred

    for size in sizes:
        size_id = str(size["id"])
        if instance_arch(size_id, size.get("extra")) == arch:
            return size_id
    return ""


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: aws_resolve_catalog.py <images.json> <sizes.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding="utf-8") as fh:
        images_payload = json.load(fh)
    with open(sys.argv[2], encoding="utf-8") as fh:
        sizes_payload = json.load(fh)

    images = images_payload.get("data", images_payload)
    sizes = sizes_payload.get("data", sizes_payload)
    if not isinstance(images, list) or not isinstance(sizes, list):
        print("expected list payloads in data", file=sys.stderr)
        return 1

    image_id = pick_image(images, ARCH)
    size_id = pick_size(sizes, ARCH)
    if not image_id or not size_id:
        print(
            f"could not resolve compatible image/size for architecture={ARCH}",
            file=sys.stderr,
        )
        return 1

    image_name = next((img.get("name", "") for img in images if img.get("id") == image_id), "")
    print(f"IMAGE_ID={image_id}")
    print(f"SIZE_ID={size_id}")
    print(f"AWS_INSTANCE_ARCH={ARCH}")
    print(f"Selected image={image_name}", file=sys.stderr)
    print(f"Selected size={size_id} arch={ARCH}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
