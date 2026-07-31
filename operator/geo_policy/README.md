# GeoPolicy operator contract

This directory owns the VPS3 GeoPolicy canary intent. Runtime state and fetched
data are not secrets, but they are generated and accepted separately from code.

1. Copy `config.yml.example` to `config.yml`.
2. Generate the initial RU dataset:

   ```powershell
   .\tools\geo_policy\refresh_dataset.ps1 -AcceptInitial
   ```

3. Copy `sha256` from `data/ru_ipv4.json` into
   `geo_policy.dataset.accepted_sha256`.
4. Collect and rank the available non-RU egress candidates. The current VPS3
   canary set is exactly `vps1`, `vps2`, and `vps4`:

   ```powershell
   python -m tools.geo_policy.collect_candidates `
     --aliases vps1,vps2,vps4 `
     --output operator/geo_policy/egress-ranking.proposal.json
   ```

5. Check the observed two-letter country codes against the
   [official OpenAI supported-country list](https://help.openai.com/en/articles/5347006-openai-api-supported-countries-and-territories/).
   Record the source URL, UTC check time, accepted codes, and each path's exact
   country code in `config.yml`.
6. Provision and accept every ranked transport gateway on the VPS3 policy
   network. For the current three-node canary, the platform-router contract
   must expose exact defaults and rules for marks
   `0x530003`/`0x530004`/`0x530005` and tables `5301`/`5302`/`5303`.
   Each remote egress must have a return path and NAT. Copy the ordered paths
   into `config.yml`, set `approval_id` to the exact proposal ID, then change
   `state` to `accepted`. The `paths` list may later grow or shrink without a
   code change; one accepted path is valid but has no redundancy.
7. Run only the mutation-free preflight:

   ```powershell
   .\tools\services\service_remote.ps1 geo_policy apply -Limit vps3 -Check
   ```

Do not run real apply until the preflight confirms every configured gateway, the dataset
checksum, the nftables candidate, IPv4-only source containers, and zero runtime
mutations.

Manual override is explicit and uses the same preflight:

```powershell
.\tools\services\service_remote.ps1 geo_policy apply `
  -Limit vps3 `
  -GeoPolicyActivePath vps2 `
  -Check
```

Without `-GeoPolicyActivePath`, `auto` preserves the active alias from the
current receipt when that alias still exists; otherwise it selects the first
configured path. When changing path count, remove a path only after its
replacement contract is green. A rollback to a removed alias requires
temporarily restoring that alias to the accepted config.

Generated `data/`, ranking proposals, and the accepted `config.yml` remain
operator-local, matching the repository convention for current placement
intent. They are bundled to orchestration from the workstation but are not
committed. `config.yml.example` documents the versioned schema.
