# Deployment

Deployment is platform-driven after product repositories publish container images.

## Flow

1. Product repository runs lint, tests, and build.
2. Product repository publishes image to GHCR with commit SHA and release tags.
3. Product repository may trigger this repository through `repository_dispatch`.
4. Platform workflow validates `services.yml`.
5. Platform workflow deploys the selected image ref to the selected VPS stack.
6. Platform workflow runs healthcheck and records rollback metadata.

## Source References

`services.yml` may contain temporary `bootstrap_ref` values while product `main` and `develop` branches are not ready. These refs identify the current source branch for building images, but deployment should still use immutable image refs produced by product CI.

When a product repository is ready, merge the bootstrap branch into `develop`, create the production `main` or release tag as appropriate, and mark the bootstrap ref as historical or remove it from the active policy.

Real deployment is intentionally not enabled in the initial skeleton.
