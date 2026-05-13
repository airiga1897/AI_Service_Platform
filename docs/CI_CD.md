# CI/CD

## Model

Products build, platform deploys.

## Product repositories

Product repositories are responsible for:

- lint and tests;
- Docker image build;
- publishing images to GHCR;
- optional `repository_dispatch` to platform repo.

## Platform repository

This repository is responsible for:

- validating service registry and stack metadata;
- rendering deploy configuration;
- deploying selected image refs to selected VPS stacks;
- healthchecks and rollback metadata.

## GitHub Environments

Recommended environments:

- `aromaflow-work`
- `aromaflow-demo`
- `ai-retail-mvp`
- `ai-retail-dev`
- `vps1-prod`
- `vps2-preprod`
- `vps3-management`
