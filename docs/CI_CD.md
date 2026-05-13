# CI/CD

## Model

Products build, platform deploys.

## Product repositories

Product repositories are responsible for:

- lint and tests;
- Docker image build;
- publishing images to GHCR;
- optional `repository_dispatch` to platform repo.

Branch names describe source/build policy only. Temporary feature branches are recorded in `services.yml` as `bootstrap_ref` until product `develop`, `main`, or release tags are ready.

## Platform repository

This repository is responsible for:

- validating service registry and stack metadata;
- rendering deploy configuration;
- deploying selected immutable image refs to selected VPS stacks;
- healthchecks and rollback metadata.

Deploy inputs should prefer Docker image refs tagged with commit SHA or release tag. A branch name must not be the only production deployment identifier.

## GitHub Environments

Recommended environments:

- `aromaflow-work`
- `aromaflow-demo`
- `ai-retail-mvp`
- `ai-retail-dev`
- `vps1-prod`
- `vps2-preprod`
- `vps3-management`
