# Deployment

Deployment is platform-driven after product repositories publish container images.

## Flow

1. Product repository runs lint, tests, and build.
2. Product repository publishes image to GHCR with commit SHA and release tags.
3. Product repository may trigger this repository through `repository_dispatch`.
4. Platform workflow validates `services.yml`.
5. Platform workflow deploys the selected image ref to the selected VPS stack.
6. Platform workflow runs healthcheck and records rollback metadata.

Real deployment is intentionally not enabled in the initial skeleton.
