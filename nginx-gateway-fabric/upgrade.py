#!/usr/bin/env python3
# upgrade-template: external-oci

# ============================================================
# Configuration (ONLY section that differs between scripts)
# To reuse this script for other OCI Helm charts, copy this file
# and modify ONLY the variables below.
# ============================================================
CONFIG = {
    "SCRIPT_NAME":            "NGINX Gateway Fabric Helm Chart Upgrade Script",
    "HELM_REPO_NAME":         "nginx-gateway-fabric",                      # informational only for OCI
    "HELM_REPO_URL":          "oci://ghcr.io/nginx/charts",                # informational only for OCI
    "HELM_CHART":             "oci://ghcr.io/nginx/charts/nginx-gateway-fabric",
    "GITHUB_REPO":            "nginx/nginx-gateway-fabric",                # for Releases API (latest version)
    "GITHUB_TAG_PREFIX":      "v",                                         # NGF tags: v2.5.1 -> 2.5.1
    "CHANGELOG_URL":          "https://github.com/nginx/nginx-gateway-fabric/releases",
    "CHART_TYPE":             "external",
    "WRAPPER_CHART_YAML":     False,
    "HELMFILE_TRACKED_CHART": "",
}
# ============================================================

# ── canonical body (sync-managed, do not edit below) ────────
import sys
from pathlib import Path

_here = Path(__file__).resolve().parent
for _anc in [_here, *_here.parents]:
    if (_anc / "scripts" / "python" / "upgrade_core").is_dir():
        sys.path.insert(0, str(_anc / "scripts" / "python"))
        break

from upgrade_core.external_oci import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
