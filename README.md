# AI Service Platform

Infra-only orchestration repository for services deployed across the AI Service Platform.

Product source code lives in separate repositories:

- `airiga1897/AromaFlowAI`
- `airiga1897/AI_E_Retail`

This repository owns platform-level runtime metadata, VPS layout, edge routing templates, stack templates, deployment playbooks, and CI/CD orchestration rules. It must not vendor product source code and does not use git submodules in the first stage.

## Runtime Instances

- `aromaflow-work` - working AromaFlowAI site.
- `aromaflow-demo` - AromaFlowAI demo-data site.
- `ai-retail-mvp` - frozen AI_E_Retail MVP.
- `ai-retail-dev` - AI_E_Retail development copy.

## CI/CD Model

Products build and publish images. This platform repository validates `services.yml` and deploys selected image refs to selected VPS stacks.

Product repository branches are tracked as build/source policy, not as deployment artifacts. While product `main` and `develop` branches are still being prepared, `services.yml` records temporary `bootstrap_ref` values for the current working product branches. Real deployment should use immutable Docker image refs tagged by commit SHA or release tag.

Initial workflows are validate-only or manual skeletons. Real deploy is enabled only after product image builds are stable.
