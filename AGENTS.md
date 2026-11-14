# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this project is

`gaia` is the **shared infrastructure** repo of the **celestialstudio** stack. It contains
no application code — only one AWS CloudFormation/SAM template describing the long-lived,
cross-service resources that the other repos (`polaris`, `altarf`, `castor`, ...) import
rather than create.

Everything lives in [aws/template.yaml](aws/template.yaml) and is deployed per environment
by [infra.sh](infra.sh) as stack `gaia-<env>-stack` in region **ap-east-2**.

## Layout

```
aws/template.yaml   the entire stack — RDS subnet group, MySQL instance, SQS queue, Outputs
infra.sh            package + deploy wrapper: ./infra.sh <env>
packaged.yaml       build output of `cloudformation package` — gitignored, never commit it
README.md           one line
```

## What the stack owns

| Resource | Name | Notes |
| --- | --- | --- |
| `AWS::RDS::DBSubnetGroup` | `celestial-studio-${TargetEnvr}-subnet-group` | three hardcoded subnet IDs |
| `AWS::RDS::DBInstance` | `celestial-studio-mysql-${TargetEnvr}` | MySQL 8.4.5, `db.t4g.micro`, 20 GB gp2, single-AZ, **publicly accessible** |
| `AWS::SQS::Queue` | `polaris-${TargetEnvr}-logger-queue` | long polling 20 s; `polaris` consumes it, it is *not* defined in the polaris repo |

## Exports and their consumers

The `Outputs` section is the public API of this repo. Other stacks `Fn::ImportValue` these:

| Export | Consumed by |
| --- | --- |
| `celestial-studio-${TargetEnvr}-db-endpoint` | `polaris`, `altarf`, `castor` (lambda `MYSQL_DB_HOST`) |
| `polaris-${TargetEnvr}-logger-queue-arn` | `polaris` (lambda `logger` event source mapping) |
| `polaris-${TargetEnvr}-logger-queue-url` | `altarf` (publishes API log messages) |

**CloudFormation refuses to change or delete an export while another stack imports it.**
Renaming an export, or any edit that forces replacement of the underlying resource, means
the dependent stacks must be updated to stop importing it first, then this stack, then the
dependents again. Plan that order before touching `Outputs`.

## Conventions

- Resource names are always `!Sub`-ed with `${TargetEnvr}` — never hardcode an environment
  into a name. `TargetEnvr` is the only parameter; it is passed by `infra.sh` from `$1`.
- Shared-infra names use the `celestial-studio-` prefix; resources owned by gaia on behalf
  of a single service keep that service's prefix (hence `polaris-...-logger-queue`).
- Every new resource that another repo needs to reference gets an `Outputs` entry with an
  `Export.Name` following the same `<owner>-${TargetEnvr}-<thing>` pattern.
- Secrets come from SSM at deploy time, never from the template: the DB password resolves
  from `{{resolve:ssm:mysql-${TargetEnvr}-admin-pwd}}`. Note this is **plain `resolve:ssm`**,
  so the parameter is a String, not a SecureString (`resolve:ssm-secure` would be needed for
  that). The parameter must already exist in the target account/region or the deploy fails.
- The template declares `Transform: AWS::Serverless-2016-10-31` and a `Globals.Function`
  timeout, but there are no serverless resources yet. Harmless; leave it unless you remove
  the SAM dependency deliberately.
- Keep the section banner comments (`##### AWS RDS ... #####`) when adding resources —
  it is the only structure a single-file template has.

## Deploy

```sh
./infra.sh <env>     # e.g. ./infra.sh test
```

That runs `cloudformation package` (artifact bucket `y-cf-midway-ap-east-2`) then
`cloudformation deploy --stack-name gaia-<env>-stack --parameter-overrides TargetEnvr=<env>
--no-fail-on-empty-changeset --capabilities CAPABILITY_NAMED_IAM`.

- **There is no CI in this repo.** Unlike the sibling services (`polaris` has
  `.github/workflows/{dev,prod}.yml`), gaia is deployed by hand from a workstation with AWS
  credentials. Pushing to `dev` or `master` deploys nothing.
- Environment names follow the stack-wide convention: `test` for the `dev` branch's
  environment and `prod` for production. `infra.sh` will accept any string, which is exactly
  how a stray stack gets created — pass the env explicitly and check it in the echoed banner.
- Default working branch is `dev`; `master` is production.
- There is nothing to lint or test. Validate changes with
  `aws cloudformation validate-template --template-body file://aws/template.yaml`, and
  inspect the change set (`aws cloudformation deploy --no-execute-changeset`, or
  `create-change-set` + `describe-change-set`) before applying anything to `prod`.

## Gotchas

- **This stack holds the only copy of production data.** The RDS instance has no
  `DeletionProtection`, no `BackupRetentionPeriod`, and no `DeletionPolicy`, so a template
  mistake is unrecoverable. Changing `DBInstanceIdentifier`, `Engine`, `DBSubnetGroupName`
  or the subnet list **replaces** the instance; changing `AllocatedStorage`,
  `DBInstanceClass`, `EngineVersion` or `MasterUserPassword` is an in-place (but
  possibly downtime-causing) update. Check the resource's "Update requires" column in the
  AWS docs for anything you edit here, and never assume a rename is cosmetic.
- `MasterUsername: admin` cannot be changed after creation (replacement only).
- Subnet IDs are hardcoded and the instance has no `VPCSecurityGroups`, so it lands in the
  VPC's default security group. Access is controlled out-of-band — if a service cannot
  reach the database, the fix is usually a security-group rule in the console, not this
  template.
- `PubliclyAccessible: true` is deliberate (services and local tooling connect over the
  internet). Don't flip it without checking every consumer; it also triggers a replacement-
  free but connectivity-breaking update.
- Database **schema** is not managed here. DDL lives with the services (e.g. `polaris/db/*.sql`)
  and is applied by hand. gaia creates the server, nothing inside it.
- `packaged.yaml` in the working tree is generated and gitignored. It will look stale/divergent
  from `aws/template.yaml`; ignore it, don't edit it, don't commit it.
- An empty change set is not an error (`--no-fail-on-empty-changeset`), so a "successful"
  deploy does not prove your edit was applied — confirm via the stack events or by
  describing the resource.
