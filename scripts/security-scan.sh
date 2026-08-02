#!/usr/bin/env bash

set -uo pipefail

readonly TRIVY_IMAGE='docker.io/aquasec/trivy@sha256:e2b22eac59c02003d8749f5b8d9bd073b62e30fefaef5b7c8371204e0a4b0c08'
readonly TRIVY_SEVERITIES='HIGH,CRITICAL'
readonly TRIVY_TMPFS_SIZE='256m'
scan_state_directory=''

emit_status() {
  local scanner="$1"
  local status="$2"
  local reason="$3"

  printf '{"type":"security_scan_status","scanner":"%s","status":"%s","reason":"%s"}\n' \
    "$scanner" "$status" "$reason"
}

emit_self_test_status() {
  local test_name="$1"
  local status="$2"

  printf '{"type":"security_scan_self_test","test":"%s","status":"%s"}\n' \
    "$test_name" "$status"
}

resolve_repository_root() {
  local script_directory
  local expected_root
  local git_root

  script_directory="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" ||
    return 1
  expected_root="$(CDPATH= cd -- "$script_directory/.." && pwd -P)" ||
    return 1
  git_root="$(git -C "$expected_root" rev-parse --show-toplevel 2>/dev/null)" ||
    return 1
  git_root="$(CDPATH= cd -- "$git_root" && pwd -P)" ||
    return 1

  validate_repository_mount "$git_root" "$expected_root" || return 1
  printf '%s\n' "$git_root"
}

validate_repository_mount() {
  local candidate="$1"
  local expected="$2"
  local canonical_candidate
  local canonical_expected

  canonical_candidate="$(CDPATH= cd -- "$candidate" 2>/dev/null && pwd -P)" ||
    return 1
  canonical_expected="$(CDPATH= cd -- "$expected" 2>/dev/null && pwd -P)" ||
    return 1

  [[ "$canonical_candidate" == "$canonical_expected" ]]
}

validate_trivy_image() {
  local image="$1"

  [[ "$image" == "$TRIVY_IMAGE" ]] &&
    [[ "$image" =~ ^docker\.io/aquasec/trivy@sha256:[0-9a-f]{64}$ ]]
}

has_existing_snyk_authentication() {
  if [[ -n "${SNYK_TOKEN:-}" || -n "${SNYK_OAUTH_TOKEN:-}" ]]; then
    return 0
  fi

  snyk config get api 2>/dev/null |
    grep -Eqv '^[[:space:]]*(undefined|null)?[[:space:]]*$' &&
    return 0

  snyk config get oauthToken 2>/dev/null |
    grep -Eqv '^[[:space:]]*(undefined|null)?[[:space:]]*$'
}

run_snyk_gate() {
  local snyk_output_file="${1:-}"
  local snyk_status

  if ! command -v snyk >/dev/null 2>&1; then
    emit_status snyk BLOCKED binary_missing
    return 2
  fi

  if ! has_existing_snyk_authentication; then
    emit_status snyk BLOCKED authentication_missing
    return 2
  fi

  if [[ -z "$snyk_output_file" ]]; then
    emit_status snyk FAIL output_path_missing
    return 1
  fi

  emit_status snyk RUNNING existing_authentication_detected
  SNYK_DISABLE_ANALYTICS=1 snyk test --severity-threshold=high \
    >"$snyk_output_file" 2>&1
  snyk_status=$?

  sed -E \
    -e 's/(SNYK_TOKEN|SNYK_OAUTH_TOKEN|token|authorization)([=:][[:space:]]*)[^[:space:]]+/\1\2[REDACTED]/Ig' \
    "$snyk_output_file"

  if grep -Eq 'SNYK-0005|Authentication error|401 Unauthorized' "$snyk_output_file"; then
    emit_status snyk BLOCKED authentication_rejected
    return 2
  fi

  if [[ "$snyk_status" -eq 0 ]]; then
    emit_status snyk PASS no_high_or_critical_findings
    return 0
  fi

  emit_status snyk FAIL scan_failed_or_findings_present
  return 1
}

summarize_trivy_report() {
  local report_path="$1"

  node - "$report_path" <<'NODE'
const fs = require("node:fs");

const reportPath = process.argv[2];

try {
  const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
  let findingCount = 0;

  for (const result of report.Results ?? []) {
    const target = result.Target ?? "";

    for (const vulnerability of result.Vulnerabilities ?? []) {
      findingCount += 1;
      console.log(JSON.stringify({
        type: "security_scan_finding",
        scanner: "trivy",
        kind: "vulnerability",
        target,
        severity: vulnerability.Severity ?? "UNKNOWN",
        id: vulnerability.VulnerabilityID ?? "",
        package: vulnerability.PkgName ?? "",
        installed_version: vulnerability.InstalledVersion ?? "",
        fixed_version: vulnerability.FixedVersion ?? "",
        title: vulnerability.Title ?? "",
      }));
    }

    for (const misconfiguration of result.Misconfigurations ?? []) {
      findingCount += 1;
      console.log(JSON.stringify({
        type: "security_scan_finding",
        scanner: "trivy",
        kind: "misconfiguration",
        target,
        severity: misconfiguration.Severity ?? "UNKNOWN",
        id: misconfiguration.ID ?? "",
        title: misconfiguration.Title ?? "",
        status: misconfiguration.Status ?? "",
      }));
    }

    for (const secret of result.Secrets ?? []) {
      findingCount += 1;
      console.log(JSON.stringify({
        type: "security_scan_finding",
        scanner: "trivy",
        kind: "secret",
        target,
        severity: secret.Severity ?? "UNKNOWN",
        rule_id: secret.RuleID ?? "",
        category: secret.Category ?? "",
        title: secret.Title ?? "",
        start_line: secret.StartLine ?? null,
      }));
    }
  }

  console.log(JSON.stringify({
    type: "security_scan_summary",
    scanner: "trivy",
    findings: findingCount,
  }));
  process.exitCode = findingCount === 0 ? 0 : 10;
} catch {
  console.error("Trivy report could not be parsed safely.");
  process.exitCode = 11;
}
NODE
}

run_installed_trivy() {
  local repository_root="$1"
  local scan_state_directory="$2"
  local report_path="$3"

  emit_status trivy RUNNING installed_binary
  trivy --version
  trivy fs \
    --cache-dir "$scan_state_directory/cache" \
    --exit-code 1 \
    --format json \
    --no-progress \
    --output "$report_path" \
    --scanners vuln,misconfig,secret \
    --severity "$TRIVY_SEVERITIES" \
    "$repository_root"
}

run_container_trivy() {
  local repository_root="$1"
  local scan_state_directory="$2"
  local scan_status
  local container_user

  container_user="$(id -u):$(id -g)"

  if ! validate_trivy_image "$TRIVY_IMAGE"; then
    emit_status trivy FAIL image_not_digest_pinned
    return 1
  fi

  if ! command -v docker >/dev/null 2>&1; then
    emit_status trivy BLOCKED binary_and_container_runtime_missing
    return 2
  fi

  emit_status trivy RUNNING digest_pinned_container

  docker run --rm --pull=always \
    --user "$container_user" \
    --cap-drop=ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs "/tmp:rw,noexec,nosuid,nodev,size=$TRIVY_TMPFS_SIZE" \
    --mount "type=bind,src=$scan_state_directory,dst=/scan-state" \
    "$TRIVY_IMAGE" image \
    --cache-dir /scan-state/cache \
    --download-db-only \
    --no-progress
  scan_status=$?

  if [[ "$scan_status" -ne 0 ]]; then
    emit_status trivy FAIL vulnerability_database_download_failed
    return 1
  fi

  docker run --rm --pull=never \
    --user "$container_user" \
    --network=none \
    --cap-drop=ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs "/tmp:rw,noexec,nosuid,nodev,size=$TRIVY_TMPFS_SIZE" \
    --mount "type=bind,src=$repository_root,dst=/workspace,readonly" \
    --mount "type=bind,src=$scan_state_directory,dst=/scan-state" \
    --workdir /workspace \
    "$TRIVY_IMAGE" fs \
    --cache-dir /scan-state/cache \
    --exit-code 1 \
    --format json \
    --no-progress \
    --output /scan-state/trivy.json \
    --scanners vuln,misconfig,secret \
    --severity "$TRIVY_SEVERITIES" \
    --skip-check-update \
    --skip-db-update \
    /workspace
}

run_trivy_gate() {
  local repository_root="$1"
  local scan_state_directory="$2"
  local report_path="$scan_state_directory/trivy.json"
  local scan_status
  local summary_status

  mkdir -p -- "$scan_state_directory/cache"

  if command -v trivy >/dev/null 2>&1; then
    run_installed_trivy "$repository_root" "$scan_state_directory" "$report_path"
    scan_status=$?
  else
    run_container_trivy "$repository_root" "$scan_state_directory"
    scan_status=$?
  fi

  if [[ "$scan_status" -eq 2 ]]; then
    return 2
  fi

  if [[ ! -s "$report_path" ]]; then
    emit_status trivy FAIL report_missing
    return 1
  fi

  summarize_trivy_report "$report_path"
  summary_status=$?

  if [[ "$scan_status" -eq 0 && "$summary_status" -eq 0 ]]; then
    emit_status trivy PASS no_high_or_critical_findings
    return 0
  fi

  if [[ "$summary_status" -eq 10 ]]; then
    emit_status trivy FAIL high_or_critical_findings_present
    return 1
  fi

  emit_status trivy FAIL scan_or_report_failed
  return 1
}

cleanup_scan_state() {
  local scan_state_directory="${1:-}"

  if [[ -n "$scan_state_directory" &&
    -d "$scan_state_directory" &&
    "$(basename -- "$scan_state_directory")" == voya-security-scan.* ]]; then
    rm -rf -- "$scan_state_directory"
  fi
}

run_self_test() {
  local repository_root
  local snyk_output
  local snyk_status
  local cleanup_probe
  local failures=0

  repository_root="$(resolve_repository_root)" || {
    emit_self_test_status repository_resolution FAIL
    return 1
  }

  if validate_trivy_image 'docker.io/aquasec/trivy:0.67.2'; then
    emit_self_test_status unpinned_image_rejected FAIL
    failures=$((failures + 1))
  else
    emit_self_test_status unpinned_image_rejected PASS
  fi

  if validate_repository_mount / "$repository_root"; then
    emit_self_test_status mount_escape_rejected FAIL
    failures=$((failures + 1))
  else
    emit_self_test_status mount_escape_rejected PASS
  fi

  if cleanup_probe="$(mktemp -d -t voya-security-scan.self-test.XXXXXX)" && [[ -n "$cleanup_probe" ]]; then
    cleanup_scan_state "$cleanup_probe"
    if [[ -e "$cleanup_probe" ]]; then
      emit_self_test_status cleanup_scope FAIL
      failures=$((failures + 1))
    else
      emit_self_test_status cleanup_scope PASS
    fi
  else
    emit_self_test_status cleanup_scope FAIL
    failures=$((failures + 1))
  fi

  snyk_output="$(PATH=/nonexistent run_snyk_gate)"
  snyk_status=$?
  if [[ "$snyk_status" -ne 0 &&
    "$snyk_output" == *'"scanner":"snyk","status":"BLOCKED"'* &&
    "$snyk_output" != *'"scanner":"snyk","status":"PASS"'* ]]; then
    emit_self_test_status missing_snyk_is_blocked PASS
  else
    emit_self_test_status missing_snyk_is_blocked FAIL
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    emit_status self_test PASS all_guards_enforced
    return 0
  fi

  emit_status self_test FAIL guard_regression
  return 1
}

main() {
  local repository_root
  local trivy_status
  local snyk_status

  if [[ "${1:-}" == '--self-test' && "$#" -eq 1 ]]; then
    run_self_test
    return $?
  fi

  if [[ "$#" -ne 0 ]]; then
    printf 'Usage: %s [--self-test]\n' "$0" >&2
    return 64
  fi

  repository_root="$(resolve_repository_root)" || {
    emit_status trivy BLOCKED repository_mount_validation_failed
    emit_status snyk BLOCKED preceding_guard_failed
    emit_status overall BLOCKED repository_mount_validation_failed
    return 2
  }

  scan_state_directory="$(mktemp -d -t voya-security-scan.XXXXXX)" || {
    emit_status trivy BLOCKED temporary_cache_unavailable
    emit_status snyk BLOCKED preceding_guard_failed
    emit_status overall BLOCKED temporary_cache_unavailable
    return 2
  }
  trap 'cleanup_scan_state "$scan_state_directory"' EXIT

  run_trivy_gate "$repository_root" "$scan_state_directory"
  trivy_status=$?

  run_snyk_gate "$scan_state_directory/snyk.txt"
  snyk_status=$?

  if [[ "$trivy_status" -eq 0 && "$snyk_status" -eq 0 ]]; then
    emit_status overall PASS all_scanners_passed
    return 0
  fi

  if [[ "$trivy_status" -eq 1 || "$snyk_status" -eq 1 ]]; then
    emit_status overall FAIL scanner_failed_or_findings_present
    return 1
  fi

  emit_status overall BLOCKED required_scanner_unavailable
  return 2
}

main "$@"
