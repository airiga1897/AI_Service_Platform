# Architecture

AI Service Platform is an infra/orchestration repository. It coordinates multiple product repositories without merging their source code.

## Repository Boundaries

- `AromaFlowAI` owns application code for `aromaflow-work` and `aromaflow-demo` images.
- `AI_E_Retail` owns application code for `ai-retail-mvp` and `ai-retail-dev` images.
- `AI_Service_Platform` owns platform registry, VPS layout, edge routing, stack templates, deploy playbooks, and runbooks.

## Non-Goals

- No product source code in this repository.
- No git submodules in the first stage.
- No real secrets in this repository.
- No deploy from archives.
