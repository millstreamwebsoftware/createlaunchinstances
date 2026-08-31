# Create Launch Instance

`createlaunchinstance` creates an AMI from a selected EC2 instance and prepares
a new version of the Millstream production Auto Scaling launch template.

The script treats the current default launch template as the configuration
source of truth. A new version inherits that default and overrides only
`ImageId`; it never builds template data from a running instance.

## Safety model

Before changing AWS resources, the script:

1. Uses an explicit AWS CLI profile and verifies the Millstream AWS account.
2. Verifies the expected launch template ID and name.
3. Rejects a default template containing instance-specific placement, subnet,
   private IP, network-interface, or root-snapshot data.
4. Validates the selected instance state and checks that its AMI architecture
   and virtualization type work with the template's instance type.
5. Reuses a pending AMI only when AWS reports that it came from the selected
   source instance.
6. Creates the new template version from the current default with only an AMI
   override.
7. Reads the new version back and verifies that no other template field changed.
8. Refuses promotion if the default version changed concurrently.

Creating a launch template version does not fully validate whether EC2 can
launch it. These checks prevent the instance-specific fields and stale root
snapshot that made earlier generated versions unsafe for Auto Scaling.

## Usage

Read-only validation and preview:

```bash
./createlaunchinstance
./createlaunchinstance i-1234567890abcdef0
```

Debug mode defaults to the `millstream-readonly` AWS profile. It performs real
read-only account, template, instance, AMI, and Auto Scaling validation; it does
not create resources.

Create and optionally promote an AMI:

```bash
./createlaunchinstance --live
./createlaunchinstance --live i-1234567890abcdef0
```

Live mode defaults to `millstream-readwrite`. Its MFA-backed session must be
primed before use. Override the profile explicitly when necessary:

```bash
./createlaunchinstance --profile millstream-readonly i-1234567890abcdef0
./createlaunchinstance --live --profile millstream-readwrite i-1234567890abcdef0
```

Use `--help` for the complete command syntax.

## Live-mode effects

Live mode asks separately before it:

1. Creates the AMI.
2. Creates the launch template version.
3. Makes that version the default.

For a running source, `CreateImage` explicitly uses AWS's reboot behavior to
produce a consistent image. The script warns before confirmation. If the source
belongs to the production Auto Scaling Group, it also requires at least two
Healthy/InService instances, but it does not drain traffic itself.

Changing the default affects future Auto Scaling launches only. The script does
not replace existing instances or start an instance refresh.

If a later validation fails, the AMI and any non-default template version
already created are retained for inspection; the unsafe version is never made
default.

## Configuration

The script targets:

- Region: `ap-southeast-2`
- Launch template: `Millstream-App-Server-Template`
- Auto Scaling Group: `Millstream-Production-Auto-Scaling-Group`
- Debug profile: `millstream-readonly`
- Live profile: `millstream-readwrite`

AMI polling defaults to every 15 seconds with a one-hour timeout. These can be
adjusted for a run:

```bash
AMI_POLL_INTERVAL_SECONDS=30 \
AMI_WAIT_TIMEOUT_SECONDS=7200 \
./createlaunchinstance --live i-1234567890abcdef0
```

## Optimization boundary

This is an image-promotion script, not an EC2 right-sizing tool. It deliberately
preserves the current template's instance type and other settings. The existing
`c3.large` and paravirtual AMI require a separately tested HVM migration before
moving to a current-generation instance family. Storage type, EBS encryption,
and IMDSv2 should likewise be changed and verified as explicit infrastructure
work rather than being hidden inside an AMI update.

## Requirements

- Bash
- AWS CLI v2
- `awk`
- `jq`
- `diff`
- `fzf` for interactive selection

Read-only validation uses permissions including:

- `sts:GetCallerIdentity`
- `ec2:DescribeInstances`
- `ec2:DescribeInstanceTypes`
- `ec2:DescribeImages`
- `ec2:DescribeLaunchTemplates`
- `ec2:DescribeLaunchTemplateVersions`
- `autoscaling:DescribeAutoScalingGroups`

Live mode additionally requires:

- `ec2:CreateImage`
- `ec2:CreateLaunchTemplateVersion`
- `ec2:ModifyLaunchTemplate`

## Tests

Run the local regression suite with:

```bash
./tests/createlaunchinstance_test.sh
```

The tests use a fake AWS CLI and never contact or modify AWS. They cover account
validation, unsafe template rejection, source-specific pending AMIs, read-only
debug behavior, image-only template inheritance, successful promotion, and
refusal to promote an unsafe generated version.
