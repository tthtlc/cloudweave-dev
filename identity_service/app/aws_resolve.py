from __future__ import annotations

from typing import Any

# Compact port of test_script/scripts/aws_resolve_catalog.py — picks an
# architecture-compatible (x86_64 by default) AMI + instance type pair so the
# final POST /v1/compute/nodes isn't rejected for arch mismatch.

ARM_FAMILIES = {
    "a1", "c6g", "c6gd", "c6gn", "c7g", "c7gd", "c7gn", "c8g", "c8gd", "c8gn",
    "g5g", "hpc7g", "i4g", "im4gn", "is4gen", "m6g", "m6gd", "m7g", "m7gd",
    "m8g", "m8gd", "m9g", "m9gd", "r6g", "r6gd", "r7g", "r7gd", "r8g", "r8gd",
    "t4g", "x2gd",
}
CANONICAL_OWNER_ID = "099720109477"  # Canonical's AWS account (official Ubuntu AMIs)
DEFAULT_SIZE_BY_ARCH = {"x86_64": "t3.small", "arm64": "m9gd.large"}


def instance_arch(size_id: str, extra: dict[str, Any] | None = None) -> str:
    extra = extra or {}
    if "Graviton" in str(extra.get("physicalProcessor", "")):
        return "arm64"
    if size_id.split(".", 1)[0] in ARM_FAMILIES:
        return "arm64"
    return "x86_64"


def _image_arch(img: dict[str, Any]) -> str:
    return str((img.get("extra") or {}).get("architecture") or "x86_64")


def _image_score(img: dict[str, Any]) -> int:
    name = str(img.get("name", "")).lower()
    extra = img.get("extra") or {}
    score = 0
    if str(extra.get("owner_id")) == CANONICAL_OWNER_ID:
        score += 200
    if "ubuntu/images/hvm-ssd-gp3/ubuntu-noble" in name:
        score += 150
    if "ubuntu/images/hvm-ssd/ubuntu-jammy" in name:
        score += 140
    if "ubuntu/images/hvm-ssd" in name:
        score += 120
    if name.startswith("ubuntu/images"):
        score += 100
    if "hvm" in name and "ssd" in name:
        score += 10
    if "deep learning" in name or "nvidia" in name or "gpu" in name:
        score -= 40
    if "22.04 lts" in name or "ubuntu 22.04" in name:
        score += 20
    if "24.04 lts" in name or "ubuntu 24.04" in name:
        score += 35
    return score


def pick_image(images: list[dict[str, Any]], arch: str = "x86_64") -> str:
    candidates = [i for i in images if _image_arch(i) == arch]
    pool = candidates or images
    if not pool:
        return ""
    return max(pool, key=_image_score).get("id", "")


def pick_size(sizes: list[dict[str, Any]], arch: str = "x86_64", preferred: str = "") -> str:
    if preferred and any(s.get("id") == preferred for s in sizes):
        return preferred
    default = DEFAULT_SIZE_BY_ARCH.get(arch, "m9gd.large")
    if any(s.get("id") == default for s in sizes):
        return default
    same_arch = [s for s in sizes if instance_arch(s.get("id", ""), s.get("extra")) == arch]
    if same_arch:
        return same_arch[0].get("id", "")
    return sizes[0].get("id", "") if sizes else default
