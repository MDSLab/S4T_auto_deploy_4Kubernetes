# Kubeconfig Requirements

To run the orchestration scripts, place your cluster credentials in this directory using the following naming convention. These files are referenced by `deploy-continuum.sh` and `campaign_runner.sh`.

| Filename | Tier | Description |
| :--- | :--- | :--- |
| `edge.yaml` | Edge | Gateway cluster at the edge (local ingestion). |
| `fog.yaml` | Fog | Fog cluster (mediation, normalization). |
| `cloud.yaml` | Cloud | SLICES Cloud cluster (analytics, long-term storage). |

> **Note:** The original workspace used names like `edge-local.yaml` or `fog-fog.yaml`. For the reproducibility artifact, we have standardized these to reflect the architectural layers.
