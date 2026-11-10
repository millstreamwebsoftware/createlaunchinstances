#!/usr/bin/env bash

set -u

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
readonly TEST_DIR
REPO_DIR=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd)
readonly REPO_DIR
readonly SCRIPT="$REPO_DIR/createlaunchinstance"
readonly MOCK_BIN_DIR="$TEST_DIR/helpers"
readonly TEST_INSTANCE_ID="i-00000000000000001"
readonly NEW_IMAGE_ID="ami-00000000000000002"

ORIGINAL_PATH="$PATH"
PASS_COUNT=0
FAIL_COUNT=0
TEST_STATE_DIR=""
OUTPUT=""
STATUS=0

setup_mock() {
    TEST_STATE_DIR=$(mktemp -d)
    export MOCK_STATE_DIR="$TEST_STATE_DIR"
    export MOCK_AWS_LOG="$TEST_STATE_DIR/aws.log"
    export PATH="$MOCK_BIN_DIR:$ORIGINAL_PATH"
    export AMI_WAIT_TIMEOUT_SECONDS=5
    export AMI_POLL_INTERVAL_SECONDS=1
    unset MOCK_ACCOUNT_ID MOCK_ALLOW_WRITES MOCK_PENDING_IMAGES
    unset MOCK_SELECTED_INSTANCE_HEALTH
    unset MOCK_SOURCE_TEMPLATE_MODE MOCK_NEW_TEMPLATE_MODE
    unset MOCK_ASG_VERSION MOCK_ASG_TEMPLATE MOCK_DEFAULT_VERSION MOCK_MIXED_POLICY
    unset MOCK_INSTANCE_PROFILE MOCK_SOURCE_ASG MOCK_ASG_UPDATE_FAILURE
    unset MOCK_CONCURRENT_ASG_VERSION MOCK_CONCURRENT_SUBNETS MOCK_CONCURRENT_DEFAULT
    unset MOCK_DEFAULT_UPDATE_FAILURE MOCK_ASG_READBACK_MISMATCH MOCK_CONCURRENT_DEFAULT_AFTER_ASG
    : > "$MOCK_AWS_LOG"
}

teardown_mock() {
    if [[ -n "$TEST_STATE_DIR" && -d "$TEST_STATE_DIR" ]]; then
        rm -rf "$TEST_STATE_DIR"
    fi
    TEST_STATE_DIR=""
    export PATH="$ORIGINAL_PATH"
}

run_command() {
    if OUTPUT=$("$@" 2>&1); then
        STATUS=0
    else
        STATUS=$?
    fi
}

run_live_command() {
    local answers="$1"
    shift

    if OUTPUT=$(printf '%s' "$answers" | "$@" 2>&1); then
        STATUS=0
    else
        STATUS=$?
    fi
}

assert_status() {
    local expected="$1"

    if [[ "$STATUS" -ne "$expected" ]]; then
        printf '    expected status %s, got %s\n%s\n' "$expected" "$STATUS" "$OUTPUT" >&2
        return 1
    fi
}

assert_success() {
    if [[ "$STATUS" -ne 0 ]]; then
        printf '    expected success, got status %s\n%s\n' "$STATUS" "$OUTPUT" >&2
        return 1
    fi
}

assert_failure() {
    if [[ "$STATUS" -eq 0 ]]; then
        printf '    expected failure\n%s\n' "$OUTPUT" >&2
        return 1
    fi
}

assert_output_contains() {
    local expected="$1"

    if [[ "$OUTPUT" != *"$expected"* ]]; then
        printf '    output did not contain: %s\n%s\n' "$expected" "$OUTPUT" >&2
        return 1
    fi
}

assert_log_contains() {
    local expected="$1"

    if ! grep -F -- "$expected" "$MOCK_AWS_LOG" >/dev/null; then
        printf '    AWS log did not contain: %s\n' "$expected" >&2
        sed -n '1,200p' "$MOCK_AWS_LOG" >&2
        return 1
    fi
}

assert_log_excludes() {
    local unexpected="$1"

    if grep -F -- "$unexpected" "$MOCK_AWS_LOG" >/dev/null; then
        printf '    AWS log unexpectedly contained: %s\n' "$unexpected" >&2
        sed -n '1,200p' "$MOCK_AWS_LOG" >&2
        return 1
    fi
}

assert_every_aws_call_uses_profile() {
    local missing=""

    missing=$(awk -F'\t' '
        {
            found = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "--profile") {
                    found = 1
                }
            }
            if (!found) {
                print NR ":" $0
            }
        }
    ' "$MOCK_AWS_LOG")

    if [[ -n "$missing" ]]; then
        printf '    AWS calls without --profile:\n%s\n' "$missing" >&2
        return 1
    fi
}

test_syntax() {
    run_command bash -n "$SCRIPT"
    assert_success
}

test_invalid_instance_id_fails_before_aws() {
    setup_mock
    run_command bash "$SCRIPT" not-an-instance
    assert_failure &&
        assert_output_contains "Invalid EC2 instance ID" &&
        [[ ! -s "$MOCK_AWS_LOG" ]]
    local result=$?
    teardown_mock
    return "$result"
}

test_debug_mode_validates_and_does_not_write() {
    setup_mock
    run_command bash "$SCRIPT" "$TEST_INSTANCE_ID"
    assert_success &&
        assert_output_contains "READ-ONLY PREVIEW" &&
        assert_output_contains "All other launch template fields will be inherited" &&
        assert_log_contains $'--profile\tmillstream-readonly\t' &&
        assert_log_contains "Name=source-instance-id,Values=$TEST_INSTANCE_ID" &&
        assert_log_excludes "create-image" &&
        assert_log_excludes "create-launch-template-version" &&
        assert_log_excludes "modify-launch-template" &&
        assert_log_excludes "update-auto-scaling-group" &&
        assert_log_contains "lt-03b872bbf73f81b5f" &&
        assert_log_contains "Millstream-Production-V2026" &&
        assert_log_excludes "lt-04ceb7a70df074f2a" &&
        assert_log_excludes "get-launch-template-data" &&
        assert_every_aws_call_uses_profile
    local result=$?
    teardown_mock
    return "$result"
}

test_wrong_account_is_rejected() {
    setup_mock
    export MOCK_ACCOUNT_ID="111111111111"
    run_command bash "$SCRIPT" --profile wrong-account "$TEST_INSTANCE_ID"
    assert_failure &&
        assert_output_contains "not the expected Millstream account" &&
        assert_log_excludes "describe-launch-templates"
    local result=$?
    teardown_mock
    return "$result"
}

test_unsafe_source_template_is_rejected() {
    setup_mock
    export MOCK_SOURCE_TEMPLATE_MODE=unsafe
    run_command bash "$SCRIPT" --profile test-profile "$TEST_INSTANCE_ID"
    assert_failure &&
        assert_output_contains "NetworkInterfaces[].SubnetId" &&
        assert_output_contains "BlockDeviceMappings[root].Ebs.SnapshotId" &&
        assert_log_excludes "create-image"
    local result=$?
    teardown_mock
    return "$result"
}

test_live_mode_rejects_source_outside_healthy_capacity() {
    setup_mock
    export MOCK_SELECTED_INSTANCE_HEALTH=Unhealthy
    run_command bash "$SCRIPT" --live --profile test-profile "$TEST_INSTANCE_ID"
    assert_failure &&
        assert_output_contains "not Healthy and InService" &&
        assert_log_excludes "create-image"
    local result=$?
    teardown_mock
    return "$result"
}

test_live_mode_changes_only_image_id_and_promotes() {
    setup_mock
    export MOCK_ALLOW_WRITES=true
    run_live_command $'y\ny\ny\n' bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_success &&
        assert_output_contains "Verified launch template version 25: only ImageId changed" &&
        assert_output_contains "Existing Auto Scaling instances were not replaced" &&
        assert_log_contains $'--profile\tmillstream-admin\t' &&
        assert_log_contains $'create-image\t' &&
        assert_log_contains $'--reboot\t' &&
        assert_log_contains $'create-launch-template-version\t' &&
        assert_log_contains $'--source-version\t24\t' &&
        assert_log_contains "{\"ImageId\":\"$NEW_IMAGE_ID\"}" &&
        assert_log_contains $'modify-launch-template\t' &&
        assert_log_contains $'update-auto-scaling-group\t--auto-scaling-group-name\tMillstream-Production-V2026\t--launch-template\tLaunchTemplateId=lt-03b872bbf73f81b5f,Version=25\t' &&
        assert_log_excludes "start-instance-refresh" &&
        assert_log_excludes "--desired-capacity" &&
        assert_log_excludes "get-launch-template-data" &&
        assert_every_aws_call_uses_profile &&
        [[ "$(sed -n '1p' "$TEST_STATE_DIR/default-version")" == "25" ]] &&
        [[ "$(sed -n '1p' "$TEST_STATE_DIR/asg-version")" == "25" ]]
    local result=$?
    teardown_mock
    return "$result"
}

test_matching_pending_image_is_reused() {
    setup_mock
    export MOCK_ALLOW_WRITES=true
    export MOCK_PENDING_IMAGES=one
    run_live_command $'y\ny\n' bash "$SCRIPT" --live --profile test-profile "$TEST_INSTANCE_ID"
    assert_success &&
        assert_output_contains "which was created from this instance" &&
        assert_log_excludes "create-image" &&
        assert_log_contains $'create-launch-template-version\t' &&
        assert_log_contains $'modify-launch-template\t'
    local result=$?
    teardown_mock
    return "$result"
}

test_unsafe_created_version_is_not_promoted() {
    setup_mock
    export MOCK_ALLOW_WRITES=true
    export MOCK_NEW_TEMPLATE_MODE=unsafe
    run_live_command $'y\ny\n' bash "$SCRIPT" --live --profile test-profile "$TEST_INSTANCE_ID"
    assert_failure &&
        assert_output_contains "new launch template version 25" &&
        assert_output_contains "NetworkInterfaces[].SubnetId" &&
        assert_log_contains $'create-launch-template-version\t' &&
        assert_log_excludes "modify-launch-template" &&
        assert_log_excludes "update-auto-scaling-group"
    local result=$?
    teardown_mock
    return "$result"
}

test_rejects_wrong_source_or_group() {
    setup_mock
    export "$1=$2"
    run_command bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_failure && assert_output_contains "$3" &&
        assert_log_excludes "create-image" &&
        assert_log_excludes "create-launch-template-version" &&
        assert_log_excludes "update-auto-scaling-group"
    local result=$?
    teardown_mock
    return "$result"
}

test_inherits_pinned_version_when_default_differs() {
    setup_mock
    export MOCK_ALLOW_WRITES=true MOCK_DEFAULT_VERSION=22
    run_live_command $'y\ny\ny\n' bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_success &&
        assert_log_contains $'--source-version\t24\t' &&
        assert_log_excludes $'--versions\t22\t' &&
        [[ "$(cat "$TEST_STATE_DIR/asg-version")" == 25 ]] &&
        [[ "$(cat "$TEST_STATE_DIR/default-version")" == 25 ]]
    local result=$?
    teardown_mock
    return "$result"
}

test_concurrent_change_prevents_promotion() {
    setup_mock
    export MOCK_ALLOW_WRITES=true
    export "$1=true"
    run_live_command $'y\ny\ny\n' bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_failure && assert_output_contains "$2" &&
        assert_log_contains "create-launch-template-version" &&
        assert_log_excludes "update-auto-scaling-group" &&
        assert_log_excludes "modify-launch-template"
    local result=$?
    teardown_mock
    return "$result"
}

test_asg_failure_does_not_change_default() {
    setup_mock
    export MOCK_ALLOW_WRITES=true
    export "$1=true"
    run_live_command $'y\ny\ny\n' bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_failure && assert_output_contains "$2" &&
        assert_log_contains "update-auto-scaling-group" &&
        assert_log_excludes "modify-launch-template" &&
        [[ ! -f "$TEST_STATE_DIR/default-version" ]]
    local result=$?
    teardown_mock
    return "$result"
}

test_partial_promotion_is_reported() {
    setup_mock
    export MOCK_ALLOW_WRITES=true MOCK_DEFAULT_UPDATE_FAILURE=true
    run_live_command $'y\ny\ny\n' bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_failure &&
        assert_output_contains "Auto Scaling uses 25, but updating the template default failed" &&
        assert_output_contains "Auto Scaling was verified on version 25" &&
        [[ "$(cat "$TEST_STATE_DIR/asg-version")" == 25 ]] &&
        [[ ! -f "$TEST_STATE_DIR/default-version" ]]
    local result=$?
    teardown_mock
    return "$result"
}

test_concurrent_default_after_asg_is_not_overwritten() {
    setup_mock
    export MOCK_ALLOW_WRITES=true MOCK_CONCURRENT_DEFAULT_AFTER_ASG=true
    run_live_command $'y\ny\ny\n' bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_failure && assert_output_contains "Auto Scaling was verified on version 25" &&
        assert_log_excludes "modify-launch-template" &&
        [[ "$(cat "$TEST_STATE_DIR/asg-version")" == 25 ]] &&
        [[ "$(cat "$TEST_STATE_DIR/default-version")" == 26 ]]
    local result=$?
    teardown_mock
    return "$result"
}

test_declining_promotion_preserves_both_selections() {
    setup_mock
    export MOCK_ALLOW_WRITES=true
    run_live_command $'y\ny\nn\n' bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_success &&
        assert_output_contains "Production remains on version 24" &&
        assert_log_contains "create-launch-template-version" &&
        assert_log_excludes "update-auto-scaling-group" &&
        assert_log_excludes "modify-launch-template"
    local result=$?
    teardown_mock
    return "$result"
}

test_extra_template_change_is_not_promoted() {
    setup_mock
    export MOCK_ALLOW_WRITES=true
    export MOCK_NEW_TEMPLATE_MODE="${1:-extra}"
    run_live_command $'y\ny\n' bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_failure && assert_output_contains "fields other than ImageId changed" &&
        assert_log_excludes "update-auto-scaling-group" &&
        assert_log_excludes "modify-launch-template"
    local result=$?
    teardown_mock
    return "$result"
}

test_standalone_production_builder_is_allowed() {
    setup_mock
    export MOCK_SOURCE_ASG=unmanaged
    run_command bash "$SCRIPT" "$TEST_INSTANCE_ID"
    assert_success && assert_output_contains "READ-ONLY PREVIEW" &&
        assert_log_excludes "create-image"
    local result=$?
    teardown_mock
    return "$result"
}

run_test() {
    local name="$1"
    local function_name="$2"
    shift 2

    printf 'TEST %s\n' "$name"
    if "$function_name" "$@"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '  PASS\n'
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  FAIL\n'
    fi
}

trap teardown_mock EXIT

run_test "script has valid Bash syntax" test_syntax
run_test "invalid instance ID fails before AWS" test_invalid_instance_id_fails_before_aws
run_test "debug mode validates without writes" test_debug_mode_validates_and_does_not_write
run_test "wrong AWS account is rejected" test_wrong_account_is_rejected
run_test "unsafe source template is rejected" test_unsafe_source_template_is_rejected
run_test "live mode rejects a source outside healthy capacity" test_live_mode_rejects_source_outside_healthy_capacity
run_test "live mode changes only ImageId and promotes" test_live_mode_changes_only_image_id_and_promotes
run_test "matching pending AMI is reused" test_matching_pending_image_is_reused
run_test "unsafe created version is not promoted" test_unsafe_created_version_is_not_promoted


run_test "development source is rejected" test_rejects_wrong_source_or_group MOCK_INSTANCE_PROFILE MillstreamDevelopmentCmsRole "modern production instance profile"
run_test "legacy source is rejected" test_rejects_wrong_source_or_group MOCK_INSTANCE_PROFILE MillstreamAppServerRole "modern production instance profile"
run_test "source in another ASG is rejected" test_rejects_wrong_source_or_group MOCK_SOURCE_ASG another-group "another Auto Scaling Group"
run_test "wrong production template is rejected" test_rejects_wrong_source_or_group MOCK_ASG_TEMPLATE lt-04ceb7a70df074f2a "pin a numeric version"
run_test "dynamic default selection is rejected" test_rejects_wrong_source_or_group MOCK_ASG_VERSION "\$Default" "pin a numeric version"
run_test "dynamic latest selection is rejected" test_rejects_wrong_source_or_group MOCK_ASG_VERSION "\$Latest" "pin a numeric version"
run_test "mixed policy is rejected" test_rejects_wrong_source_or_group MOCK_MIXED_POLICY true "pin a numeric version"
run_test "pinned version wins over template default" test_inherits_pinned_version_when_default_differs
run_test "concurrent ASG version prevents promotion" test_concurrent_change_prevents_promotion MOCK_CONCURRENT_ASG_VERSION "selection or subnets changed"
run_test "concurrent subnet change prevents promotion" test_concurrent_change_prevents_promotion MOCK_CONCURRENT_SUBNETS "selection or subnets changed"
run_test "concurrent default change prevents promotion" test_concurrent_change_prevents_promotion MOCK_CONCURRENT_DEFAULT "default changed"
run_test "ASG write failure leaves default unchanged" test_asg_failure_does_not_change_default MOCK_ASG_UPDATE_FAILURE "Auto Scaling update failed"
run_test "ASG readback mismatch leaves default unchanged" test_asg_failure_does_not_change_default MOCK_ASG_READBACK_MISMATCH "selection verification failed"
run_test "partial promotion is reported accurately" test_partial_promotion_is_reported
run_test "default race after ASG promotion is preserved" test_concurrent_default_after_asg_is_not_overwritten
run_test "declining promotion preserves both selections" test_declining_promotion_preserves_both_selections
run_test "other template changes block promotion" test_extra_template_change_is_not_promoted
run_test "losing public IPv4 blocks promotion" test_extra_template_change_is_not_promoted no-public-ip
run_test "standalone production builder is allowed" test_standalone_production_builder_is_allowed

printf '\n%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
