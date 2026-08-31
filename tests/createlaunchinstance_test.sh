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
    unset MOCK_SOURCE_TEMPLATE_MODE MOCK_NEW_TEMPLATE_MODE
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

test_live_mode_changes_only_image_id_and_promotes() {
    setup_mock
    export MOCK_ALLOW_WRITES=true
    run_live_command $'y\ny\ny\n' bash "$SCRIPT" --live "$TEST_INSTANCE_ID"
    assert_success &&
        assert_output_contains "Verified launch template version 25: only ImageId changed" &&
        assert_output_contains "Existing Auto Scaling instances were not replaced" &&
        assert_log_contains $'--profile\tmillstream-readwrite\t' &&
        assert_log_contains $'create-image\t' &&
        assert_log_contains $'--reboot\t' &&
        assert_log_contains $'create-launch-template-version\t' &&
        assert_log_contains $'--source-version\t24\t' &&
        assert_log_contains "{\"ImageId\":\"$NEW_IMAGE_ID\"}" &&
        assert_log_contains $'modify-launch-template\t' &&
        assert_log_excludes "get-launch-template-data" &&
        assert_every_aws_call_uses_profile &&
        [[ "$(sed -n '1p' "$TEST_STATE_DIR/default-version")" == "25" ]]
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
        assert_log_excludes "modify-launch-template"
    local result=$?
    teardown_mock
    return "$result"
}

run_test() {
    local name="$1"
    local function_name="$2"

    printf 'TEST %s\n' "$name"
    if "$function_name"; then
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
run_test "live mode changes only ImageId and promotes" test_live_mode_changes_only_image_id_and_promotes
run_test "matching pending AMI is reused" test_matching_pending_image_is_reused
run_test "unsafe created version is not promoted" test_unsafe_created_version_is_not_promoted

printf '\n%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
