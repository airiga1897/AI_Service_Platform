# validate-services-yml

Validates the current `services.yml` registry contract.

Checks include:

- the three-node VPS layout from the roadmap;
- project repository, `bootstrap_ref`, stable branch, and deploy ref policy;
- runtime env prefixes, healthchecks, and VPS deploy targets;
- SoftEther as a required platform edge/VPN component;
- SoftEther current TCP listeners and future optional UDP listeners;
- guardrails that prevent SoftEther from being owned by a runtime instance.

Run locally:

```powershell
python tools/validate-services-yml/validate_services_yml.py
```
