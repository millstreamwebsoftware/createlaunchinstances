# Create Launch Instance

A bash script to automate the creation of AWS AMI images from EC2 instances and update launch templates.

## Overview

This script automates the process of:
1. Creating an AMI from an existing EC2 instance
2. Waiting for the AMI to become available
3. Creating a new launch template version with the new AMI
4. Optionally updating the default launch template version

## Usage

```bash
# Interactive mode - select instance with fzf
./createlaunchinstance

# Specify instance ID
./createlaunchinstance i-1234567890abcdef0

# Live mode (actually execute commands)
./createlaunchinstance --live

# Live mode with specific instance
./createlaunchinstance --live i-1234567890abcdef0
```

## Modes

- **Debug Mode** (default): Shows what commands would be executed without running them
- **Live Mode** (`--live`): Executes commands with confirmation prompts

## Features

- Interactive instance selection using `fzf`
- Automatic detection of existing pending AMI creation
- Perth timezone timestamps for AMI naming
- Progress monitoring for AMI creation
- Confirmation prompts for destructive operations
- Comprehensive error handling

## Requirements

- AWS CLI configured with appropriate permissions
- `fzf` (for interactive instance selection)
- `jq` (for JSON processing)
- Bash shell

## Configuration

The script uses these default values:
- Region: `ap-southeast-2`
- Launch Template ID: `lt-04ceb7a70df074f2a`

Edit the script to modify these values as needed.

## AWS Permissions Required

The script requires AWS permissions for:
- `ec2:DescribeInstances`
- `ec2:DescribeImages` 
- `ec2:CreateImage`
- `ec2:DescribeLaunchTemplates`
- `ec2:GetLaunchTemplateData`
- `ec2:CreateLaunchTemplateVersion`
- `ec2:ModifyLaunchTemplate`