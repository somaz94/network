#!/usr/bin/env python3
# upgrade-template: argocd-pin

# ============================================================
# Configuration (ONLY section that differs between scripts)
# To reuse this script for other Helm charts, copy this file
# and modify ONLY the variables below.
# ============================================================
CONFIG = {
    "SCRIPT_NAME":    "External-DNS (AWS) Helm Chart Upgrade Script",
    "BASE":           "standard",
    "HELM_REPO_NAME": "external-dns",
    "HELM_REPO_URL":  "https://kubernetes-sigs.github.io/external-dns/",
    "HELM_CHART":     "external-dns/external-dns",
    "CHANGELOG_URL":  "https://github.com/kubernetes-sigs/external-dns/releases",
    "CHART_TYPE":     "external",  # "local" or "external"
    # ArgoCD-managed: version SSOT is argocd-aws/<release>.yaml chart.version (no helmfile).
    "ARGOCD_PIN_FILES": [
        "argocd-aws/external-dns.yaml",
    ],
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

from upgrade_core.argocd_pin import run  # noqa: E402

if __name__ == "__main__":
    sys.exit(run(CONFIG, sys.argv[1:], script_path=__file__))
