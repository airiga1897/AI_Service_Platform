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

Initial workflows are validate-only or manual skeletons. Real deploy is enabled only after product image builds are stable.
