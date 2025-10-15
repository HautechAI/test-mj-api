#!/bin/sh
# POSIX-compatible helper functions for Kie.ai Midjourney API experiments
# Do not store or read secrets from this repository.

# Fail fast in subshells; callers should check return codes.
set -u

# Logs
log() { printf '%s\n' "$*" 1>&2; }
die() { log "ERROR: $*"; exit 1; }

# Ensure required commands exist
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# Compose auth header from env
# Uses: KIE_AUTH_HEADER (default Authorization), KIE_AUTH_SCHEME (default Bearer), KIE_API_KEY (required)
auth_header_value() {
  hdr_sch=${KIE_AUTH_SCHEME:-Bearer}
  if [ -n "$hdr_sch" ]; then
    printf '%s %s' "$hdr_sch" "$KIE_API_KEY"
  else
    # Scheme empty means send only the key value
    printf '%s' "$KIE_API_KEY"
  fi
}

auth_header_key() {
  printf '%s' "${KIE_AUTH_HEADER:-Authorization}"
}

# json_get: extract a value from stdin JSON using jq path.
# Usage: echo "$json" | json_get '.data.taskId'
json_get() {
  jq_path="$1"
  jq -er "$jq_path" 2>/dev/null || return 1
}

# Internal: perform curl with retries/backoff for 429/5xx
# Args: method, url, body_or_empty, extra_headers (newline-delimited), output_file
_curl_with_retry() {
  _method="$1"; _url="$2"; _body="$3"; _headers="$4"; _out="$5"

  max_attempts=${MAX_HTTP_ATTEMPTS:-5}
  sleep_base=${HTTP_RETRY_BASE_SECONDS:-2}
  attempt=1
  while :; do
    # Build header args
    set --
    OLD_IFS=$IFS; IFS='\n'
    for h in $_headers; do
      [ -n "$h" ] && set -- "$@" -H "$h"
    done
    IFS=$OLD_IFS

    # Execute request
    if [ "$_method" = "GET" ]; then
      http_code=$(curl -sS -L -m 120 -o "$_out" -w '%{http_code}' "$@" "$_url" 2>&1)
      curl_rc=$?
    else
      http_code=$(printf '%s' "$_body" | curl -sS -L -m 120 -o "$_out" -w '%{http_code}' "$@" -X "$_method" -H 'Content-Type: application/json' --data-binary @- "$_url" 2>&1)
      curl_rc=$?
    fi

    # On curl transport error
    if [ $curl_rc -ne 0 ]; then
      log "curl failed (rc=$curl_rc) to $_url on attempt $attempt/$max_attempts"
      http_code=599
    fi

    case "$http_code" in
      2??)
        return 0
        ;;
      429|5??)
        if [ $attempt -ge $max_attempts ]; then
          log "HTTP $http_code after $attempt attempts; giving up."
          return 2
        fi
        # Exponential backoff
        sleep_sec=$((sleep_base << (attempt - 1)))
        log "HTTP $http_code from $_url; retrying in ${sleep_sec}s (attempt $attempt/$max_attempts)"
        sleep "$sleep_sec"
        attempt=$((attempt + 1))
        ;;
      *)
        # Non-retryable error
        log "HTTP $http_code from $_url; not retrying."
        return 3
        ;;
    esac
  done
}

# Public wrappers
# http_post URL JSON_BODY -> prints body to stdout, returns nonzero on error
http_post() {
  _url="$1"; _body="$2"
  tmpfile=$(mktemp)
  # Compose auth header
  hdr_key=$(auth_header_key)
  hdr_val=$(auth_header_value)
  headers="${hdr_key}: ${hdr_val}\nContent-Type: application/json"
  if _curl_with_retry "POST" "$_url" "$_body" "$headers" "$tmpfile"; then
    cat "$tmpfile"
    rm -f "$tmpfile"
    return 0
  else
    log "POST $_url failed. Response body:";
    cat "$tmpfile" 1>&2 || true
    rm -f "$tmpfile"
    return 1
  fi
}

# http_get URL -> prints body to stdout, returns nonzero on error
http_get() {
  _url="$1"
  tmpfile=$(mktemp)
  hdr_key=$(auth_header_key)
  hdr_val=$(auth_header_value)
  headers="${hdr_key}: ${hdr_val}"
  if _curl_with_retry "GET" "$_url" "" "$headers" "$tmpfile"; then
    cat "$tmpfile"
    rm -f "$tmpfile"
    return 0
  else
    log "GET $_url failed. Response body:";
    cat "$tmpfile" 1>&2 || true
    rm -f "$tmpfile"
    return 1
  fi
}

# download_file URL DEST_PATH -> returns nonzero on error
download_file() {
  _url="$1"; _dest="$2"
  # Use auth header only for provider URLs; most result URLs are public signed URLs; we don't assume auth.
  curl -sS -L --fail -o "$_dest" "$_url" || return 1
  return 0
}

