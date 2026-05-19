#!/usr/bin/env bash
set -euo pipefail

JENKINS_JOB_BASE_URL="${JENKINS_JOB_BASE_URL:-https://jenkins.int.kiban.club/job/ho-test/job/merge-train-test}"
JENKINS_TRIGGER_URL="${JENKINS_TRIGGER_URL:-}"
JENKINS_BRANCH_PARAM="${JENKINS_BRANCH_PARAM:-BRANCH_NAME}"
JENKINS_BRANCH_VALUE="${JENKINS_BRANCH_VALUE:-${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-${CI_COMMIT_REF_NAME:-}}}"
JENKINS_WAIT_TIMEOUT_SECONDS="${JENKINS_WAIT_TIMEOUT_SECONDS:-1800}"
JENKINS_POLL_SECONDS="${JENKINS_POLL_SECONDS:-10}"
JENKINS_REQUIRE_CRUMB="${JENKINS_REQUIRE_CRUMB:-auto}"
JENKINS_CRUMB_URL="${JENKINS_CRUMB_URL:-}"

url_encode() {
  jq -nr --arg value "$1" '$value|@uri'
}

if [[ -z "${JENKINS_TRIGGER_URL}" ]]; then
  if [[ -n "${JENKINS_BRANCH_PARAM}" && -n "${JENKINS_BRANCH_VALUE}" ]]; then
    encoded_branch_value="$(url_encode "${JENKINS_BRANCH_VALUE}")"
    JENKINS_TRIGGER_URL="${JENKINS_JOB_BASE_URL%/}/buildWithParameters?${JENKINS_BRANCH_PARAM}=${encoded_branch_value}"
  else
    JENKINS_TRIGGER_URL="${JENKINS_JOB_BASE_URL%/}/build"
  fi
fi

JENKINS_ROOT_URL="$(echo "${JENKINS_TRIGGER_URL}" | sed -E 's#(https?://[^/]+).*#\1#')"
JENKINS_JOB_URL="$(echo "${JENKINS_TRIGGER_URL}" | sed -E 's#/(build|buildWithParameters)(\?.*)?$##')"

AUTH_ARGS=()
if [[ -n "${JENKINS_USER:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
  AUTH_ARGS=(-u "${JENKINS_USER}:${JENKINS_API_TOKEN}")
fi

if [[ ${#AUTH_ARGS[@]} -eq 0 ]]; then
  echo "JENKINS_USER and JENKINS_API_TOKEN are required for this Jenkins integration."
  exit 1
fi

CRUMB_ARGS=()
response_headers="$(mktemp)"
trigger_response_file="$(mktemp)"
crumb_response_file="$(mktemp)"
build_response_file="$(mktemp)"
trap 'rm -f "${response_headers}" "${trigger_response_file}" "${crumb_response_file}" "${build_response_file}"' EXIT

jenkins_curl() {
  curl --silent --show-error --fail "${AUTH_ARGS[@]}" "$@"
}

setup_jenkins_crumb() {
  local crumb_url
  local crumb_http_code
  local crumb_field
  local crumb_value
  local jenkins_root

  if [[ "${JENKINS_REQUIRE_CRUMB}" == "false" ]]; then
    echo "CSRF crumb handling disabled by JENKINS_REQUIRE_CRUMB=false."
    return
  fi

  if [[ ${#AUTH_ARGS[@]} -eq 0 ]]; then
    if [[ "${JENKINS_REQUIRE_CRUMB}" == "true" ]]; then
      echo "JENKINS_REQUIRE_CRUMB=true requires JENKINS_USER and JENKINS_API_TOKEN."
      exit 1
    fi
    return
  fi

  if [[ -n "${JENKINS_CRUMB_URL}" ]]; then
    crumb_url="${JENKINS_CRUMB_URL}"
  else
    jenkins_root="${JENKINS_ROOT_URL}"
    crumb_url="${jenkins_root}/crumbIssuer/api/json"
  fi

  crumb_http_code="$(curl --silent --show-error "${AUTH_ARGS[@]}" -o "${crumb_response_file}" -w "%{http_code}" "${crumb_url}" || true)"
  if [[ "${crumb_http_code}" != "200" ]]; then
    if [[ "${JENKINS_REQUIRE_CRUMB}" == "true" ]]; then
      echo "Failed to fetch Jenkins crumb from ${crumb_url} (HTTP ${crumb_http_code})."
      exit 1
    fi
    echo "No Jenkins crumb fetched (HTTP ${crumb_http_code}), proceeding without crumb header."
    return
  fi

  crumb_field="$(jq -r '.crumbRequestField // empty' "${crumb_response_file}")"
  crumb_value="$(jq -r '.crumb // empty' "${crumb_response_file}")"

  if [[ -z "${crumb_field}" || -z "${crumb_value}" ]]; then
    if [[ "${JENKINS_REQUIRE_CRUMB}" == "true" ]]; then
      echo "Jenkins crumb response did not include crumbRequestField/crumb."
      exit 1
    fi
    echo "Jenkins crumb response missing fields, proceeding without crumb header."
    return
  fi

  CRUMB_ARGS=(-H "${crumb_field}: ${crumb_value}")
  echo "Using Jenkins CSRF crumb header ${crumb_field}."
}

to_absolute_jenkins_url() {
  local candidate="$1"

  if [[ "${candidate}" =~ ^https?:// ]]; then
    echo "${candidate}"
    return
  fi

  if [[ "${candidate}" == /* ]]; then
    echo "${JENKINS_ROOT_URL}${candidate}"
    return
  fi

  echo "${JENKINS_ROOT_URL}/${candidate}"
}

post_jenkins_trigger() {
  local url="$1"

  curl --silent --show-error "${AUTH_ARGS[@]}" "${CRUMB_ARGS[@]}" \
    -X POST -D "${response_headers}" -o "${trigger_response_file}" -w "%{http_code}" "${url}"
}

echo "Triggering Jenkins build: ${JENKINS_TRIGGER_URL}"
if [[ -n "${JENKINS_BRANCH_VALUE}" ]]; then
  echo "Requested Jenkins branch parameter ${JENKINS_BRANCH_PARAM}=${JENKINS_BRANCH_VALUE}"
fi
setup_jenkins_crumb

initial_next_build_number=""
if job_json_before_trigger="$(jenkins_curl "${JENKINS_JOB_URL}/api/json" 2>/dev/null)"; then
  initial_next_build_number="$(echo "${job_json_before_trigger}" | jq -r '.nextBuildNumber // empty')"
fi

http_code="$(post_jenkins_trigger "${JENKINS_TRIGGER_URL}")"

if [[ "${http_code}" == "400" && "${JENKINS_TRIGGER_URL}" =~ /build(\?.*)?$ && ! "${JENKINS_TRIGGER_URL}" =~ /buildWithParameters(\?.*)?$ ]]; then
  fallback_trigger_url="$(echo "${JENKINS_TRIGGER_URL}" | sed -E 's#/build(\?.*)?$#/buildWithParameters\1#')"
  echo "Jenkins returned HTTP 400 for /build; retrying with ${fallback_trigger_url}"
  http_code="$(post_jenkins_trigger "${fallback_trigger_url}")"
  if [[ "${http_code}" == "200" || "${http_code}" == "201" ]]; then
    JENKINS_TRIGGER_URL="${fallback_trigger_url}"
  fi
fi

if [[ "${http_code}" != "201" && "${http_code}" != "200" ]]; then
  echo "Jenkins trigger failed with HTTP status ${http_code}."
  if [[ -s "${trigger_response_file}" ]]; then
    echo "Jenkins trigger response body:"
    cat "${trigger_response_file}"
  fi
  exit 1
fi

queue_url_raw="$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { print $2 }' "${response_headers}" | tr -d '\r' | tail -n1)"
queue_api_url=""

if [[ -n "${queue_url_raw}" ]]; then
  queue_url="$(to_absolute_jenkins_url "${queue_url_raw}")"
  echo "Jenkins queued build at: ${queue_url}"
  queue_api_url="${queue_url%/}/api/json"
else
  echo "Jenkins did not return queue location header; using nextBuildNumber fallback."
  if [[ -n "${initial_next_build_number}" ]]; then
    build_url="${JENKINS_JOB_URL%/}/${initial_next_build_number}/"
    echo "Tracking Jenkins build URL via fallback: ${build_url}"
  else
    echo "Unable to infer build URL because nextBuildNumber is unavailable."
    echo "Jenkins trigger response headers were:"
    sed 's/\r$//' "${response_headers}"
    exit 1
  fi
fi

start_ts="$(date +%s)"
build_url="${build_url:-}"

while [[ -n "${queue_api_url}" ]]; do
  now_ts="$(date +%s)"
  elapsed="$((now_ts - start_ts))"
  if (( elapsed > JENKINS_WAIT_TIMEOUT_SECONDS )); then
    echo "Timed out waiting for Jenkins queue item to start (${JENKINS_WAIT_TIMEOUT_SECONDS}s)."
    exit 1
  fi

  queue_json="$(jenkins_curl "${queue_api_url}")"
  cancelled="$(echo "${queue_json}" | jq -r '.cancelled // false')"

  if [[ "${cancelled}" == "true" ]]; then
    why="$(echo "${queue_json}" | jq -r '.why // "No reason provided"')"
    echo "Jenkins queue item was cancelled: ${why}"
    exit 1
  fi

  build_url="$(echo "${queue_json}" | jq -r '.executable.url // empty')"
  if [[ -n "${build_url}" ]]; then
    echo "Jenkins started build: ${build_url}"
    break
  fi

  echo "Still queued in Jenkins (${elapsed}s elapsed)."
  sleep "${JENKINS_POLL_SECONDS}"
done

build_api_url="${build_url}api/json"
while true; do
  now_ts="$(date +%s)"
  elapsed="$((now_ts - start_ts))"
  if (( elapsed > JENKINS_WAIT_TIMEOUT_SECONDS )); then
    echo "Timed out waiting for Jenkins build completion (${JENKINS_WAIT_TIMEOUT_SECONDS}s)."
    exit 1
  fi

  build_http_code="$(curl --silent --show-error "${AUTH_ARGS[@]}" -o "${build_response_file}" -w "%{http_code}" "${build_api_url}" || true)"
  if [[ "${build_http_code}" == "404" ]]; then
    echo "Jenkins build not created yet (${elapsed}s elapsed)."
    sleep "${JENKINS_POLL_SECONDS}"
    continue
  fi

  if [[ "${build_http_code}" != "200" ]]; then
    echo "Failed to query Jenkins build status from ${build_api_url} (HTTP ${build_http_code})."
    exit 1
  fi

  build_json="$(cat "${build_response_file}")"
  building="$(echo "${build_json}" | jq -r '.building // false')"
  result="$(echo "${build_json}" | jq -r '.result // empty')"

  if [[ "${building}" == "false" && -n "${result}" ]]; then
    echo "Jenkins build finished with result: ${result}"
    if [[ "${result}" == "SUCCESS" ]]; then
      exit 0
    fi
    exit 1
  fi

  echo "Jenkins build in progress (${elapsed}s elapsed)."
  sleep "${JENKINS_POLL_SECONDS}"
done
