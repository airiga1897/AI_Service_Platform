# Egress Policy, Probes, And AI-Assisted Analysis

This plan reserves the next egress-policy roadmap after the VPN/HAProxy edge is
stable. It separates fact collection, AI-assisted interpretation, human approval,
and eventual routing enforcement.

## Stage Roadmap

1. Stage 1: policy registry + probes.
2. Stage 2: AI-assisted classification/reporting.
3. Stage 3: human-approved policy updates.
4. Stage 4: controlled routing enforcement.

Stage 1 must come first. It creates the operator-local target registry, probe
results, and deterministic facts that later AI analysis can consume. Stage 2
must not be mixed into routing enforcement.

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
  for automatic enforcement.

## Future Enforcement Boundary

Stage 4 may consume approved policy from Stage 3. It must not consume raw AI
guesses directly. Controlled routing can use only explicit allow/deny/prefer
rules that were reviewed by an operator and stored as policy.
