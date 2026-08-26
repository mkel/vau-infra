# vau-infra

Account-level shared infrastructure for VAU Company's AWS account 518875398948 (profile`tg`). 
Resources here are shared by many projects; no single project's repo may create, modify or destroy them. 
State is remote, in
`s3://vau-terraform-state-bucket` under `vau-infra/<root>/terraform.tfstate`.

## Roots

- `shared-web-acl/` — the one CLOUDFRONT-scoped Web ACL every site in the
  account associates for edge rate limiting. Consumers (vau-maillist
  deployments and other backend components) reference its `web_acl_arn`
  output; their rules live here, not in their own repositories. The design
  rationale and the rate-rule specification live in the vau-maillist repo,
  `doc/architecture.md` ("Rate-based rule").

## Rules of engagement

Every site in the account depends on the shared Web ACL at once. Before
changing anything in `shared-web-acl/`:

- Never `terraform destroy`, and never rename or replace the ACL — the ARN is
  referenced by other projects' state, and CloudFront distributions hold
  associations to it. A plan that shows the ACL being destroyed or replaced is
  wrong; stop and say so.
- Show the plan and wait for approval before any apply.
- New rules follow the pattern of the existing signup rule unless there is a
  stated reason otherwise:
    - a unique `priority`;
    - a scope-down statement that narrows to the component's own method and
      path, so the rule never counts other projects' traffic;
    - aggregation on source IP **and** the `Host` header with the `LOWERCASE`
      text transformation — the transformation is required, not stylistic:
      CloudFront matches alternate domain names case-insensitively while WAF
      aggregates on the literal header value, so without it each casing of a
      hostname gets its own full rate budget;
    - `sampled_requests_enabled = false` and no logging configuration — request
      logs and samples persist client IP addresses, and the projects behind
      this ACL deliberately do not store those.
- Mind the budget: the ACL has 1500 WCUs by default and a rule shaped like
  the signup rule costs ~62+. Each rule also adds $1/month.
- `terraform.tfvars` is per-machine and gitignored; commit `.tfvars.example`
  and `.terraform.lock.hcl`.
