#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/bootstrap-tailcat.sh"

VALID_KEY="nodekey:1111111111111111111111111111111111111111111111111111111111111111"
SECOND_KEY="nodekey:2222222222222222222222222222222222222222222222222222222222222222"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

expect_failure() {
    if ("$@" >/dev/null 2>&1); then
        fail "expected failure: $*"
    fi
}

validate_allowed_clients "$VALID_KEY"
validate_allowed_clients "$VALID_KEY,$SECOND_KEY"
expect_failure validate_allowed_clients "nodekey:short"
expect_failure validate_allowed_clients "none"
expect_failure validate_allowed_clients "$VALID_KEY,"

validate_derp_hosts "derp.example.com"
validate_derp_hosts "derp-a.example.com,derp-b.example.com"
expect_failure validate_derp_hosts "localhost"
expect_failure validate_derp_hosts "-bad.example.com"
expect_failure validate_derp_hosts "derp.example.com,"
expect_failure validate_derp_hosts "derp.example.com,,other.example.com"

select_package amd64 x86_64
assert_equal "$ASSET_NAME" "tailcat_0.4.0_linux_amd64.deb"
assert_equal "$PACKAGE_ARCH" "amd64"
assert_equal "$EXPECTED_SHA256" "38ff4b45fe56b32c75738c10dfed4f0b68d33bee49a19695f4bb9f9ec5d6e3c0"

select_package arm64 aarch64
assert_equal "$ASSET_NAME" "tailcat_0.4.0_linux_arm64.deb"
assert_equal "$PACKAGE_ARCH" "arm64"
assert_equal "$EXPECTED_SHA256" "8f1835a3522ecfc855c9f4ece51c2266781fd03ce76da48036b08c4b86193899"

select_package armhf armv7l
assert_equal "$ASSET_NAME" "tailcat_0.4.0_linux_armv7.deb"
assert_equal "$PACKAGE_ARCH" "armhf"
assert_equal "$EXPECTED_SHA256" "e98c18862ee1c72ad85db6653b64fdda4fbf6d14980b96f4ada63e09e2456187"
expect_failure select_package armhf armv6l
expect_failure select_package i386 i686

(parse_args --allow "$VALID_KEY" --derp derp.example.com --duration-minutes 5)
(parse_args --allow "$VALID_KEY" --public-derp --duration-minutes 1440)
expect_failure parse_args --allow "$VALID_KEY" --derp derp.example.com --public-derp
expect_failure parse_args --duration-minutes 4
expect_failure parse_args --duration-minutes 1441
expect_failure parse_args --uninstall --public-derp

requested="$(requested_relay)"
assert_equal "$requested" ""

documented_hash="$(awk -F'`' '/^Installer SHA256:/ {print $2}' "$ROOT/README.md")"
actual_hash="$(sha256sum "$ROOT/bootstrap-tailcat.sh" | awk '{print $1}')"
assert_equal "$documented_hash" "$actual_hash"
grep -q "/bootstrap-v${INSTALLER_VERSION}/bootstrap-tailcat.sh" "$ROOT/README.md" \
    || fail "README installer tag does not match installer version"

printf 'bootstrap-tailcat tests passed\n'
