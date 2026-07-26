# Milestone 7 Evidence

Milestone 7 repository implementation exists but has not been deployed or verified live. Historical M0-M6 measurements remain evidence for former coupled architecture only.

## Repository Validation

Local validation run 2026-07-26. Do not treat local results as CI or live deployment evidence.

- [x] Monitor Go tests, race tests, vet, GolangCI-Lint, govulncheck, and frontend build passed through `pre-commit run --all-files`
- [x] Workload Go tests, race tests, vet, GolangCI-Lint, govulncheck, and PostgreSQL 18 integration tests passed; integration command used `TEST_DATABASE_URL` against the Compose database
- [x] ARM64 monitor and workload container builds passed; images report `linux/arm64`, user `65534:65534`, and sizes 4,099,153 and 2,894,662 bytes respectively
- [x] `terraform fmt -check -recursive terraform`
- [x] `terraform validate` for bootstrap, monitoring, prod, and DR roots
- [x] TFLint and Checkov
- [x] Shell syntax and ShellCheck for drill scripts
- [x] Workflow validation for `terraform.yml`, `monitor.yml`, `workload.yml`, and `recovery.yml`
- [ ] Independent monitoring, prod, and DR Terraform plans reviewed
- [ ] Monitoring and workload destroy plans reviewed for state isolation

Read-only unlocked live-state plans verified monitoring foundation at 61 creates with no DNS cutover or destroys, and prod migration at two token creates, workload task-definition replacement, removal of obsolete workload topology policies, certificate replacement, and no deletion of the monitor validation CNAME. DR correctly remains blocked until prod creates `/sentinel-aws-dr/prod/link-create-token`; review it after prod apply, before DR apply.

Infracost did not produce an estimate because the local OAuth refresh token is invalid. Its fail-closed hook now uses the explicit manual stage so the documented external-auth blocker does not masquerade as a failed code check; run `pre-commit run infracost-scan --hook-stage manual --all-files` after authentication and before deployment. Docker Scout scans did not run because Docker login is absent. These two checks remain incomplete.

## Deployment Evidence

- [ ] Guarded bootstrap IAM plan reviewed and explicitly approved apply retained
- [ ] `monitor-foundation` run and monitoring role output retained
- [ ] `monitor.yml` publish-only digest retained
- [ ] `monitor-deploy` run and public monitor health retained
- [ ] Existing M6 workload foundation verified for migration, or workload `foundation` run retained for a from-empty deployment
- [ ] `workload.yml` publish-only digest and cross-region replication retained
- [ ] Workload `deploy` run with prod healthy and DR desired count zero retained
- [ ] Regional SSM parameter metadata and write-only applied-state checks retained without secret values

## Live Gates

- [ ] Monitor remains available during ECS task replacement
- [ ] Monitor remains available during controlled AZ capacity loss
- [ ] Monitor remains available during RDS Multi-AZ failover
- [ ] Monitor records regional workload outage and recovery
- [ ] Prod-created link survives failover
- [ ] DR-created link survives failback
- [ ] Fresh M7 RTO and RPO evidence retained
- [ ] Failback reset restores prod writer, DR replica, and DR desired count zero
- [ ] Monitoring resources remain unchanged through workload failover, reset, and destroy plans

## Deferred

- [ ] Canonical architecture diagram update. Deferred by owner instruction and not complete.
