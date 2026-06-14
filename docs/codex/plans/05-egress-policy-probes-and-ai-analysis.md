# Egress Policy, Probes, And AI-Assisted Analysis

This plan reserves the next egress-policy roadmap after the VPN/HAProxy edge is
stable. It separates fact collection, AI-assisted interpretation, human approval,
and eventual selective fallback routing.

## Stage Roadmap

1. Stage 1: policy registry + probes.
2. Stage 2: AI-assisted classification/reporting.
3. Stage 3: human-approved policy updates.
4. Stage 4: controlled selective fallback routing.

Stage 1 must come first. It creates the operator-local target registry, probe
results, and deterministic facts that later AI analysis can consume. Stage 2
must not be mixed into selective fallback routing.

## Stage 1 Current Interface

The v1 registry is a small operator-managed JSON file:

```text
operator/egress_policy/profiles.json
```

Only `profiles.json` is synced to the active orchestrator as operator intent.
Probe history, archives, and proposals remain operator-local evidence and review
state.

A safe tracked template is stored at:

```text
docs/examples/egress_policy.profiles.example.json
```

Profiles are global intent for all VPS nodes. They list candidate ingress
aliases, candidate fallback egress aliases, target domains or IPs, target
protocol/port, behavior, reason, state, and rollback. Per-node differences should come from node
capabilities/labels later, not from duplicating the same profile per VPS. The v1
behavior is `fallback_on_ingress_egress_failure`: ingress-local egress first,
cascade only when that local path fails or degrades. Real domains and IPs belong
in `operator/egress_policy/profiles.json`, not in code.

Target protocols are protocol-agnostic at the policy layer: `http`, `https`,
`tcp`, `udp`, and `icmp`. HTTP/HTTPS/TCP/ICMP have deterministic probes. UDP is
route-capable, but without an explicit protocol-specific probe it remains
`route_review` and is not auto-accepted.

The probe-only runner is:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1
```

Use `-DryRun` to validate and list selected profiles without SSH probes. A normal
run executes read-only SSH probes from each selected VPS and writes JSONL history
under `operator/egress_policy/history/`.

Operators can create or replace a probe-only profile without hand-editing JSON:

```powershell
.\tools\egress_policy\set_egress_policy_profile.ps1 `
  -Name example_service_fallback `
  -TargetValue example.org,www.example.org `
  -Protocol tcp `
  -Port 443 `
  -IngressAlias vps5 `
  -FallbackEgressAlias vps4 `
  -Reason "Local ingress path is unreliable for this operator-defined target." `
  -Replace
```

Related hosts are explicit, not inferred. If a probe sees a redirect to an
unlisted host, proposal generation may create `related_target_missing`; the
operator decides whether to add that host to the profile.

This command changes only `operator/egress_policy/profiles.json`.

Use `-SshPath` when the current shell resolves `ssh` to a wrapper instead of the
real OpenSSH executable:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1 -SshPath <path-to-ssh>
```

Use `-IncludeCascade` to add cascade-aware readiness observations. That mode
loads explicit links from `operator/softether/cascade/secrets/lab-cascade.json`
when present, with legacy per-pair JSON files used only when the unified file is
absent. It checks ingress-to-receiver TCP reachability, reads SoftEther cascade
status, then probes the target from the final egress alias. It is still
probe-only and does not enable routing/NAT or move user traffic.

Each cascade link has `state`. Missing or `active` means a real lab link,
`probe` means read-only candidate, and `disabled` is ignored. Probe-only links
are useful as negative/control routes: the runner records whether transport and
SoftEther status are usable, but it must not create the cascade connection or
promote the route.

Use `-PreferCascade` for the normal operator workflow: probe ingress-local
egress first and run explicit cascade fallback links only when the local path
fails or degrades. Use `-CascadeOnly` when the operator wants to inspect only
cascade candidates.

Render the latest history for humans with:

```powershell
.\tools\egress_policy\report_egress_probes.ps1
```

Generate and review operator-visible proposals with:

```powershell
.\tools\egress_policy\suggest_egress_policy.ps1 -DryRun
.\tools\egress_policy\report_egress_proposals.ps1
.\tools\egress_policy\review_egress_proposals.ps1
.\tools\egress_policy\set_egress_proposal_status.ps1 -Id <proposal-id> -Status accepted -Reason "operator approved"
```

AI advisory proposals use the same inbox but remain suggestions:

```powershell
.\tools\egress_policy\new_egress_ai_advisory_proposal.ps1 `
  -TargetValue example.org `
  -Protocol tcp `
  -Port 443 `
  -Summary "AI suggests reviewing this target based on observed failures."
```

Accepted or rejected proposals are still not active routing policy. They only
record the operator decision and prepare a later explicit profile/route patch.

The proposal inbox is exception-only. A target that is already covered by policy
and has a clearly good observation, such as `good_ingress_local`, is stored in
history but does not require approval. Proposals are generated only for decisions
that need human attention: unknown targets, ingress-local failure with fallback
available, fallback unavailable, probe errors, unstable retries, or inconclusive
route evidence. This keeps large target lists manageable for the operator.

Per-VPS candidate collection is handled by the standalone
`edge_candidate_collector` service:

```csv
service,edge_candidate_collector,edge_candidate_collectors,vps1+vps2+vps3+vps4+vps5,,,present
```

Each selected VPS runs its own local collector timer. The collector reads only
sanitized HAProxy, policy-gateway, and vpn-cascade symptoms and writes JSONL
under `/var/lib/ai-service-platform/edge_candidate_collector/candidates/`.
Operator-side aggregation pulls those JSONL records and creates safe proposals:

```powershell
.\tools\egress_policy\collect_egress_candidates.ps1 -AllAliases
.\tools\egress_policy\collect_egress_candidates.ps1 -IngressAlias vps4
```

After a successful fetch and proposal generation, the operator may archive
remote evidence without deleting it immediately:

```powershell
.\tools\egress_policy\collect_egress_candidates.ps1 `
  -IngressAlias vps4 `
  -ArchiveRemoteAfterFetch
```

That mode moves remote `candidates/*.jsonl` into the collector `processed/`
directory. Both `candidates/` and `processed/` are TTL-cleaned by the collector
runner; raw docker logs remain separate and are not exposed to operator fetch.

These proposals use `source=edge_candidate_collector` and `status=suggested`.
The collector and aggregator never apply selective fallback, routes, NAT,
firewall, HAProxy config, Docker config, or SoftEther changes.

If ingress-local probing fails or degrades after all attempts and exactly one
configured fallback egress alias succeeds for a target already present in
`profiles.json`, the `fallback_available` proposal is automatically marked
`accepted` / `Принято`. This is still proposal state only; routing is not applied.

Old `desired_region_behavior`, `candidate_egress_aliases`, and
`candidate_fallback_links` fields are not part of the v1 contract. Strict
country policy, if needed later, must be an explicit behavior such as
`require_non_ru_egress`.

Human-facing review output uses Russian status text:
`Требует решения`, `Принято`, `Отклонено`, `Отложено`, and `Устарело`.
The interactive review command keeps short action keys: `A`, `R`, `I`, `D`, `S`,
and `Q`.

The report emits recommendations such as `good_ingress_local`,
`fallback_available`, `fallback_unavailable`, `probe_error`, or `route_review`
from observations only. It includes retry count and HTTP response timing, but
must not apply routing, firewall, NAT, HAProxy, Docker, or SoftEther changes.

## Stage 1 Inputs Required For AI

The probe and log pipeline should collect structured, sanitized facts:

- egress probe results: target, source VPS alias, source public IP, TCP/TLS/HTTP
  status, latency, timeout/reset, redirect chain, selected response metadata;
- HAProxy TCP logs: frontend/backend, source IP, SNI where available, reject or
  deny reason, rate-limit symptoms, management-port probes;
- SoftEther status/log facts: container status, listener availability, selected
  operational events, sanitized connection summaries;
- rollout/postcheck failures: service name, alias, task name, exit code,
  validation failure, restart/recreate signal.

Raw secrets, private keys, passwords, tokens, full VPN configs, and sensitive
payloads must not become AI inputs.

## Stage 2 AI-Assisted Classification

AI can classify and summarize sanitized facts after deterministic parsers extract
the evidence. Useful categories:

- sanctions or geo block;
- WAF or bot challenge;
- auth-required versus actual access block;
- scanner or abuse traffic;
- DNS/CDN mismatch;
- route degradation between previous and current probe runs.

AI output should be findings, explanations, and proposed policy patches. Example:

```text
finding: probable geo/sanctions block
target: registry-1.docker.io
affected_egress: vps1
evidence: HTTP 403 + block-like body + same target OK from vps4
recommendation: prefer vps4 for docker_hub, keep vps1 denied until manual review
action: no automatic routing change
```

## Safety Rules

- AI analyzes sanitized facts, not raw logs or secrets.
- Deterministic parsers run before AI and preserve the factual record.
- AI must not apply firewall, HAProxy, routing, rollout, or SoftEther changes.
- Policy updates are human-approved only.
- If classification is uncertain, the result stays advisory and must not be used
  for automatic selective fallback routing.

## Future Selective Fallback Boundary

Stage 4 may consume approved policy from Stage 3. It must not consume raw AI
guesses directly. Controlled selective fallback routing can use only explicit
fallback rules that were reviewed by an operator and stored as policy.

Stage 4 canaries must be repeatable and self-auditing. A route apply should
record resolved target IPs under operator state, verify the exact edge route,
ingress cascade route through `tap_vpnpolicy`, egress return route, scoped NAT,
and then prove traffic from the `softether-edge` network namespace when the
protocol supports a generic check. Rollback must use persisted applied state and
verify the exact route/NAT entries are gone.
