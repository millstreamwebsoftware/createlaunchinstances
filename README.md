# Create Launch Instance

`createlaunchinstance` creates an AMI from a selected modern production EC2
instance or production image-builder and prepares a new launch-template version
for `Millstream-Production-V2026` in the Millstream AWS account.

The **numeric version selected by the production Auto Scaling group** is the
configuration source of truth. The new version inherits it and overrides only
`ImageId`. Promotion explicitly selects the new version on the group, then
updates the template default. Merely changing the default would not change the
version pinned by modern production.

## Safety model

Before changing AWS resources, the script:

1. Uses an explicit AWS profile and verifies account `450153405013` and the
   expected modern production launch-template ID/name.
2. Verifies that `Millstream-Production-V2026` directly selects a numeric version
   of that template. Mixed-instance policies and `$Default`/`$Latest` selection
   are rejected instead of silently changing their behavior.
3. Rejects template data containing instance-specific placement, subnet, private
   IP, network-interface IDs or a stale root snapshot.
4. Requires the source instance to use the modern production instance profile
   and VPC. Development and legacy sources, and members of other Auto Scaling
   groups, are rejected. Standalone builders using the production role are
   allowed after the existing source confirmation.
5. Validates the source state and AMI architecture/virtualization compatibility.
6. Reuses a pending AMI only when AWS reports that it came from that source.
7. Creates a version with an `ImageId`-only override, then reads it back and
   compares the complete configuration to the inherited version.
8. Rechecks the original group selection, subnets and template default before
   creating a version and again before promotion, refusing detected drift.
9. Updates only the group's launch-template selection, verifies it, then updates
   and verifies the template default. Capacity, subnets, load-balancer attachments
   and existing instances are not modified by these calls.

The modern public-IP setting, production instance role, security groups, storage,
metadata options and user data are inherited unchanged. These checks do not
boot-test a newly created AMI or prove application health. A fresh-instance test
remains a separate step before using an image for a production replacement.

## Usage

Read-only validation and preview:

```bash
./createlaunchinstance
./createlaunchinstance i-1234567890abcdef0
```

Normal mode defaults to `millstream-readonly` and performs real account,
Auto Scaling, template, instance and AMI reads. Interactive selection lists only
running/stopped instances in the production VPC with the production profile.
No AWS resources are changed by preview mode.

Live mode creates the AMI and offers promotion:

```bash
aws sts get-caller-identity --profile millstream-admin
./createlaunchinstance --live
./createlaunchinstance --live i-1234567890abcdef0
```

Prime the MFA-backed `millstream-admin` session yourself first. It is the live
default because selecting a launch template with the production instance role
requires `iam:PassRole`, which `millstream-readwrite` does not grant. An explicitly
supplied profile must have the required permissions:

```bash
./createlaunchinstance --profile millstream-readonly i-1234567890abcdef0
./createlaunchinstance --live --profile millstream-admin i-1234567890abcdef0
```

## Live effects and recovery

There are three separate confirmations:

1. Create the AMI.
2. Create the launch-template version.
3. Select that version for future production Auto Scaling launches and make it
   the template default. Declining leaves both selections unchanged.

For a running source, `CreateImage` explicitly requests a reboot for a consistent
image. The script warns before confirmation. A running production group member
must be Healthy/InService, with at least two healthy InService group members.
The script does not drain traffic; use an appropriately prepared standalone
production builder when rebooting a serving instance is unsuitable.

Promotion affects future launches. It does **not** start an instance refresh,
terminate existing instances, or change desired/minimum/maximum capacity.

Group selection and template-default changes are two separate AWS writes:

- A group update/readback failure stops before changing the template default.
  A failed API request can still have been applied; inspect the actual group.
- If the group update succeeds but the default update fails or a concurrent
  default change is detected, the group remains on the verified new version.
  The script reports this partial state and exits unsuccessfully.
- No automatic rollback overwrites concurrent operator changes. Inspect the
  group and default before retrying. AMIs and newly created versions are retained.

The pre-write checks detect observed drift but are not an atomic lock across AWS
API calls. Avoid concurrent promotions of the same production group/template.

## Configuration

- Region: `ap-southeast-2`
- Launch template: `Millstream-Production-V2026` (`lt-03b872bbf73f81b5f`)
- Auto Scaling group: `Millstream-Production-V2026`
- Source instance profile: `MillstreamProductionV2026Role`
- Source VPC: `vpc-03322748c5824b11f`
- AMI name prefix: `millstream-production-v2026-`
- Preview profile: `millstream-readonly`
- Live profile: `millstream-admin`

No template version, image ID, public IP or subnet is baked into the promotion
flow. The active group selection is read each run. The retired
`Millstream-App-Server-Template` and `Millstream-Production-Auto-Scaling-Group`
are not used.

AMI polling defaults to 15 seconds with a one-hour timeout:

```bash
AMI_POLL_INTERVAL_SECONDS=30 \
AMI_WAIT_TIMEOUT_SECONDS=7200 \
./createlaunchinstance --live i-1234567890abcdef0
```

## Requirements and verification

Runtime dependencies: Bash (including macOS Bash 3.2), AWS CLI v2, `awk`, `jq`,
`diff`, and `fzf` for interactive selection.

Read permissions include `sts:GetCallerIdentity`, `ec2:DescribeInstances`,
`ec2:DescribeInstanceTypes`, `ec2:DescribeImages`, `ec2:DescribeLaunchTemplates`,
`ec2:DescribeLaunchTemplateVersions` and
`autoscaling:DescribeAutoScalingGroups`.

Live mode additionally needs `ec2:CreateImage`, `ec2:CreateLaunchTemplateVersion`,
`ec2:ModifyLaunchTemplate`, `autoscaling:UpdateAutoScalingGroup`, and the
[launch-template usage permissions](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-launch-template-permissions.html)
including `ec2:RunInstances` and `iam:PassRole` for the existing production role.

There are no hosted CI workflows in this repository. Run all local checks before
committing or pushing:

```bash
for script in createlaunchinstance tests/createlaunchinstance_test.sh tests/helpers/aws; do
  bash -n "$script"
done
shellcheck createlaunchinstance tests/createlaunchinstance_test.sh tests/helpers/aws
./tests/createlaunchinstance_test.sh
git diff --check
```

The tests use a fake AWS CLI and never contact or modify AWS. They cover modern
resource targeting, source isolation, image-only inheritance, differing default
and pinned versions, concurrent changes, decline/failure/partial promotion,
and the existing account/template/AMI protections. A real read-only preview
against a current production instance validates the live integration separately.
