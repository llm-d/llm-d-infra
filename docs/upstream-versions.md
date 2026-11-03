# Upstream Dependency Version Tracking

> This file is the source of truth for the upstream dependency monitor workflow.
> It tracks all external dependencies pinned in this repository, their current versions,
> and where they are pinned. The `upstream-monitor` agentic workflow reads this file daily
> to detect when upstream projects release new versions that may break llm-d.

## Docker Build Dependencies

Pinned under `docker/` in llm-d/llm-d. llm-d/llm-d#2339 removed `docker/Dockerfile.cuda`; GPU guides use upstream vLLM and SGLang images, so these pins cover the CPU, XPU and RDMA tools images:

| Dependency | Current Pin | Pin Type | File Location | Upstream Repo |
|-----------|-------------|----------|---------------|---------------|
| **vLLM** | `ced6857afa0ea7b2e3f0846a62e1394e90f15607` | commit SHA | `docker/common-versions` line 6 (`VLLM_COMMIT_SHA`, CPU image) | [vllm-project/vllm](https://github.com/vllm-project/vllm) |
| **vLLM XPU base image** | `v0.30.0` | tag | `docker/common-versions` line 11 (`VLLM_XPU_BASE_IMAGE`) | [vllm-project/vllm](https://github.com/vllm-project/vllm) |
| **SGLang (XPU)** | `94602c9c2b7cbdb8efd5c52802dac6a1c180089e` | commit SHA | `docker/common-versions` line 18 (`SGLANG_XPU_REF`) | [sgl-project/sglang](https://github.com/sgl-project/sglang) |
| **Python** | `3.12` | version | `docker/Dockerfile.cpu` line 9 | [python/cpython](https://github.com/python/cpython) |
| **UCX** | `v1.19.x` | branch | `docker/scripts/cpu/install_nixl.py` line 109 | [openucx/ucx](https://github.com/openucx/ucx) |
| **NIXL** | `0.6.1` | tag | `docker/scripts/cpu/install_nixl.py` line 134 | [ai-dynamo/nixl](https://github.com/ai-dynamo/nixl) |
| **LMCache** | `v0.5.0` | tag | `docker/Dockerfile.xpu` line 30 | [LMCache/LMCache](https://github.com/LMCache/LMCache) |
| **GDRCOPY** | `v2.5.2` | tag | `docker/Dockerfile.rdma-tools` line 11 | [NVIDIA/gdrcopy](https://github.com/NVIDIA/gdrcopy) |

## Helm Chart Dependencies

Pinned in guide helmfiles (`guides/*/helmfile.yaml.gotmpl`):

| Dependency | Current Pin | File Location | Upstream Repo / Registry |
|-----------|-------------|---------------|--------------------------|
| **llm-d-infra chart** | `v1.3.6` | All `helmfile.yaml.gotmpl` files | [llm-d-incubation/llm-d-infra](https://github.com/llm-d-incubation/llm-d-infra) (`https://llm-d-incubation.github.io/llm-d-infra/`) |
| **InferencePool chart** | `v1.3.0` | All `helmfile.yaml.gotmpl` files | [kubernetes-sigs/gateway-api-inference-extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) (`oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool`) |
| **llm-d-modelservice chart** | `v0.4.5` | All `helmfile.yaml.gotmpl` files | [llm-d-incubation/llm-d-modelservice](https://github.com/llm-d-incubation/llm-d-modelservice) (`https://llm-d-incubation.github.io/llm-d-modelservice/`) |

## Gateway Provider Dependencies

Pinned in `guides/prereq/gateway-provider/`:

| Dependency | Current Pin | File Location | Upstream Repo |
|-----------|-------------|---------------|---------------|
| **Gateway API CRDs** | `v1.4.0` | `install-gateway-provider-dependencies.sh` line 39 | [kubernetes-sigs/gateway-api](https://github.com/kubernetes-sigs/gateway-api) |
| **Gateway API Inference Extension CRDs** | `v1.3.0` | `install-gateway-provider-dependencies.sh` line 46 | [kubernetes-sigs/gateway-api-inference-extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) |
| **Istio** | `1.28.1` | `istio.helmfile.yaml` | [istio/istio](https://github.com/istio/istio) |
| **kgateway** | `v2.1.1` | `kgateway.helmfile.yaml` | [kgateway-dev/kgateway](https://github.com/kgateway-dev/kgateway) |
| **agentgateway** | `v2.2.0-beta.3` | `agentgateway.helmfile.yaml` | [kgateway-dev/kgateway](https://github.com/kgateway-dev/kgateway) |

## CI Workflow Dependencies

| Dependency | Current Pin | File Location | Notes |
|-----------|-------------|---------------|-------|
| **LeaderWorkerSet (LWS)** | `0.7.0` | `e2e-wide-ep-accelerator-test.yaml` line 387 | Also in nightly LWS workflows |
| **InferencePool (GKE)** | `v1.2.1` | `e2e-wide-ep-accelerator-gke.yaml` line 45 | **STALE** — helmfiles use v1.3.0 |

## Hardware-Specific vLLM Images

| Variant | Current Pin | File Location | Upstream |
|---------|-------------|---------------|----------|
| **vLLM TPU** | `v0.13.2-ironwood` | `guides/*/values_tpu.yaml` | [vllm-project/vllm](https://github.com/vllm-project/vllm) |
