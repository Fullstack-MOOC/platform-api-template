#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  echo "Secure submission failed. Review the messages above for remediation steps." >&2
}

cleanup() {
  [[ -n "${RUN_LOG_FILE:-}" && -f "$RUN_LOG_FILE" ]] && rm -f "$RUN_LOG_FILE"
}

trap 'on_error' ERR
trap cleanup EXIT
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXECUTION_DIR="$PWD"
DEFAULT_RESULTS_PATH="$EXECUTION_DIR/cypress-results.json"
DEFAULT_ENCRYPTED_PATH="$EXECUTION_DIR/submission/submission.enc"
RESULTS_PATH="$DEFAULT_RESULTS_PATH"
ENCRYPTED_PATH="$DEFAULT_ENCRYPTED_PATH"
ENCRYPTED_PATH_SET=false
KEEP_PLAINTEXT=false
INITIAL_PART_ID="${PART_ID:-}"
PART_ID="sPTbn"
DEFAULT_PART_ID="xyz"
SECRET_ENV_VAR="CYPRESS_RESULTS_SECRET"
SECRET_FILE=""
DEFAULT_SECRET_VALUE="your-long-passphrase"
REPORTER="json"
REPORTER_OPTIONS=""
CYPRESS_RUNNER="${CYPRESS_RUNNER:-npx}"
CYPRESS_BIN="${CYPRESS_BIN:-cypress}"
CYPRESS_SUBCOMMAND="${CYPRESS_SUBCOMMAND:-run}"
SKIP_TESTS=false
EXTRA_CYPRESS_ARGS=()
BROWSER_CHOICE=""
RUN_LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/cypress-run-XXXXXX.log")"
LOG_ARCHIVE_PATH="$EXECUTION_DIR/cypress-run.log"
rm -f "$LOG_ARCHIVE_PATH" >/dev/null 2>&1 || true

usage() {
  cat <<'USAGE'
Usage: ./scripts/run_secure_cypress.sh [options] [-- <extra cypress args>]

Runs Cypress (via npx), writes JSON results, encrypts them, and emits an upload-ready encrypted artifact.

Options:
  -r, --results <path>       Path for the plaintext Cypress JSON (default: ./cypress-results.json)
  -e, --encrypted <path>     Path for the encrypted output (default: ./submission/submission.enc)
  -b, --browser <name>       Shorthand for passing --browser to Cypress
  -k, --keep-plaintext       Preserve the plaintext JSON after encryption
      --secret-env <name>    Environment variable containing the passphrase (default: CYPRESS_RESULTS_SECRET)
      --secret-file <path>   Read passphrase from the given file (overrides --secret-env)
      --reporter <name>      Cypress reporter to use (default: json)
      --reporter-options <o> Reporter options string (output path is enforced)
      --skip-tests           Skip running Cypress and only (re-)encrypt an existing JSON file
      --part-id <id>         Override the hardcoded part ID (optional)
      --cypress-arg <arg>    Append an additional argument to the Cypress command (repeatable)
  -h, --help                 Show this help message

You can also pass "--" followed by raw Cypress CLI arguments.
USAGE
}

resolve_path() {
  local target="$1"
  if [[ "$target" == /* ]]; then
    printf '%s\n' "$target"
  else
    printf '%s/%s\n' "$PWD" "$target"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--results)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --results" >&2; exit 1; }
      RESULTS_PATH="$(resolve_path "$1")"
      if ! $ENCRYPTED_PATH_SET; then
        ENCRYPTED_PATH="$RESULTS_PATH.enc"
      fi
      ;;
    -e|--encrypted)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --encrypted" >&2; exit 1; }
      ENCRYPTED_PATH="$(resolve_path "$1")"
      ENCRYPTED_PATH_SET=true
      ;;
    -b|--browser)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --browser" >&2; exit 1; }
      BROWSER_CHOICE="$1"
      ;;
    -k|--keep-plaintext)
      KEEP_PLAINTEXT=true
      ;;
    --secret-env)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --secret-env" >&2; exit 1; }
      SECRET_ENV_VAR="$1"
      ;;
    --secret-file)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --secret-file" >&2; exit 1; }
      SECRET_FILE="$(resolve_path "$1")"
      ;;
    --reporter)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --reporter" >&2; exit 1; }
      REPORTER="$1"
      ;;
    --reporter-options)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --reporter-options" >&2; exit 1; }
      REPORTER_OPTIONS="$1"
      ;;
    --skip-tests)
      SKIP_TESTS=true
      ;;
    --part-id)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --part-id" >&2; exit 1; }
      PART_ID="$1"
      ;;
    --cypress-arg)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --cypress-arg" >&2; exit 1; }
      EXTRA_CYPRESS_ARGS+=("$1")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      if [[ $# -gt 0 ]]; then
        EXTRA_CYPRESS_ARGS+=("$@")
      fi
      break
      ;;
    *)
      EXTRA_CYPRESS_ARGS+=("$1")
      ;;
  esac
  shift || true
done

if [[ -z "$PART_ID" ]]; then
  if [[ -n "${partId:-}" ]]; then
    PART_ID="$partId"
  elif [[ -n "${COURSE_PART_ID:-}" ]]; then
    PART_ID="$COURSE_PART_ID"
  elif [[ -n "${LAB_PART_ID:-}" ]]; then
    PART_ID="$LAB_PART_ID"
  elif [[ -n "${INITIAL_PART_ID:-}" ]]; then
    PART_ID="$INITIAL_PART_ID"
  fi
fi

if [[ -z "$PART_ID" ]]; then
  PART_ID="$DEFAULT_PART_ID"
fi

mkdir -p "$(dirname "$RESULTS_PATH")"
mkdir -p "$(dirname "$ENCRYPTED_PATH")"

if [[ -z "$REPORTER_OPTIONS" ]]; then
  REPORTER_OPTIONS="output=${RESULTS_PATH},overwrite=true,includePending=true"
fi
if [[ "$REPORTER_OPTIONS" != *"output="* ]]; then
  REPORTER_OPTIONS+="${REPORTER_OPTIONS:+,}output=${RESULTS_PATH}"
fi

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command '$cmd' is not available on PATH" >&2
    exit 1
  fi
}

require_command "$CYPRESS_RUNNER"
require_command openssl

set_default_secret() {
  if [[ -z "$SECRET_FILE" ]] && [[ -z "${!SECRET_ENV_VAR-}" ]]; then
    if [[ -n "$PART_ID" ]]; then
      export "$SECRET_ENV_VAR"="$PART_ID"
    else
      echo "Warning: No secret provided. Using default insecure secret." >&2
      export "$SECRET_ENV_VAR"="$DEFAULT_SECRET_VALUE"
    fi
  fi
}

HASH_CMD=()
if command -v shasum >/dev/null 2>&1; then
  HASH_CMD=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD=(sha256sum)
else
  echo "Warning: Could not find shasum or sha256sum; hash file will be skipped" >&2
fi

run_cypress() {
  if $SKIP_TESTS; then
    echo "Re-using existing Cypress results at $RESULTS_PATH"
    return
  fi

  local run_dir="$PWD"
  local config_args=()
  local found_config=""
  local config_abs=""
  local config_dir=""

  for candidate in "cypress.config.js" "cypress.config.ts" "cypress.config.mjs" "cypress.config.cjs" "cypress.json"; do
    if [[ -f "$candidate" ]]; then
      found_config="$candidate"
      break
    fi
  done

  if [[ -z "$found_config" ]]; then
    local search_path
    search_path="$(find "$ROOT_DIR" -maxdepth 4 -type f \( -name "cypress.config.js" -o -name "cypress.config.ts" -o -name "cypress.config.mjs" -o -name "cypress.config.cjs" -o -name "cypress.json" \) -print -quit 2>/dev/null || true)"
    if [[ -n "$search_path" ]]; then
      found_config="$search_path"
    fi
  fi

  if [[ -n "$found_config" ]]; then
    config_abs="$(resolve_path "$found_config")"
    config_args+=(--config-file "$config_abs")
    config_dir="$(cd "$(dirname "$config_abs")" && pwd)"
    run_dir="$config_dir"
  fi

  rm -f "$RESULTS_PATH"
  local cmd=("$CYPRESS_RUNNER")
  [[ -n "$CYPRESS_BIN" ]] && cmd+=("$CYPRESS_BIN")
  [[ -n "$CYPRESS_SUBCOMMAND" ]] && cmd+=("$CYPRESS_SUBCOMMAND")
  cmd+=("--reporter" "$REPORTER" "--reporter-options" "$REPORTER_OPTIONS")

  if [[ ${#config_args[@]} -gt 0 ]]; then
    cmd+=("${config_args[@]}")
  fi

  if [[ -n "$config_dir" && -d "$config_dir/cypress/e2e" ]]; then
    local spec_files
    spec_files="$(find "$config_dir/cypress/e2e" -name "*.cy.js" -o -name "*.cy.ts" | head -n 1)"
    if [[ -n "$spec_files" ]]; then
      if [[ "$spec_files" == *.cy.js ]]; then
        cmd+=(--spec "$config_dir/cypress/e2e/**/*.cy.js")
      elif [[ "$spec_files" == *.cy.ts ]]; then
        cmd+=(--spec "$config_dir/cypress/e2e/**/*.cy.ts")
      else
        cmd+=(--spec "$config_dir/cypress/e2e")
      fi
    fi
  fi

  if [[ ${#EXTRA_CYPRESS_ARGS[@]} -gt 0 ]]; then
    cmd+=("${EXTRA_CYPRESS_ARGS[@]}")
  fi

  echo "Executing Cypress suite..."
  local cypress_exit_code=0
  if ! (
    cd "$run_dir"
    "${cmd[@]}"
  ) >"$RUN_LOG_FILE" 2>&1; then
    cypress_exit_code=$?
    cp "$RUN_LOG_FILE" "$LOG_ARCHIVE_PATH" >/dev/null 2>&1 || true
    echo "Cypress execution completed with exit code $cypress_exit_code. Attempting to extract results from log..." >&2
    # Don't exit here - allow the script to try recovering JSON from the log
  fi
  return $cypress_exit_code
}

read_secret() {
  local secret=""
  if [[ -n "$SECRET_FILE" ]]; then
    if [[ ! -r "$SECRET_FILE" ]]; then
      echo "Cannot read secret file: $SECRET_FILE" >&2
      exit 1
    fi
    secret="$(< "$SECRET_FILE")"
  else
    secret="${!SECRET_ENV_VAR-}"
    if [[ -z "$secret" ]]; then
      secret="$DEFAULT_SECRET_VALUE"
      export "$SECRET_ENV_VAR"="$secret"
    fi
  fi
  secret="$(printf '%s' "$secret" | tr -d '\r\n')"
  if [[ -z "$secret" ]]; then
    echo "Encryption secret not provided. Set $SECRET_ENV_VAR or use --secret-file." >&2
    exit 1
  fi
  printf '%s' "$secret"
}

set_default_secret
if [[ -n "$BROWSER_CHOICE" ]]; then
  EXTRA_CYPRESS_ARGS+=("--browser" "$BROWSER_CHOICE")
fi

echo "Preparing secure submission..."
run_cypress

if [[ ! -s "$RESULTS_PATH" ]]; then
  echo "Unable to locate Cypress results at $RESULTS_PATH" >&2
  if [[ -s "$RUN_LOG_FILE" ]]; then
    echo "Attempting to recover JSON results from captured Cypress output..."
    if ! command -v python3 >/dev/null 2>&1; then
      echo "python3 is required to recover results from the Cypress log." >&2
      exit 1
    fi
    if python3 - "$RUN_LOG_FILE" "$RESULTS_PATH" <<'PY'
import json
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
text = log_path.read_text(encoding="utf-8", errors="ignore")
start = None
depth = 0

for idx, ch in enumerate(text):
    if ch == "{":
        if depth == 0:
            start = idx
        depth += 1
    elif ch == "}":
        if depth == 0:
            continue
        depth -= 1
        if depth == 0 and start is not None:
            snippet = text[start : idx + 1]
            try:
                parsed = json.loads(snippet)
            except json.JSONDecodeError:
                start = None
                continue
            if isinstance(parsed, dict) and "stats" in parsed:
                out_path.parent.mkdir(parents=True, exist_ok=True)
                out_path.write_text(json.dumps(parsed, indent=2), encoding="utf-8")
                sys.exit(0)
            start = None

print("Failed to extract JSON block from Cypress output.", file=sys.stderr)
sys.exit(1)
PY
    then
      echo "Recovered results JSON at $RESULTS_PATH"
    else
      echo "Unable to reconstruct Cypress results; aborting." >&2
      exit 1
    fi
  else
    exit 1
  fi
fi

encrypt_results() {
  local secret_value
  secret_value="$(read_secret)"
  local secret_env="OPENSSL_PASSPHRASE_$$"
  export "$secret_env"="$secret_value"
  if ! openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in "$RESULTS_PATH" -out "$ENCRYPTED_PATH" -pass "env:$secret_env"; then
    echo "Secure submission could not be created. Ensure you are using the correct partId/secret for this lab." >&2
    unset "$secret_env"
    exit 1
  fi
  unset "$secret_env"
}

encrypt_results

if ! $KEEP_PLAINTEXT; then
  rm -f "$RESULTS_PATH"
fi

HASH_VALUE=""
if [[ ${#HASH_CMD[@]} -gt 0 ]]; then
  HASH_OUTPUT="$("${HASH_CMD[@]}" "$ENCRYPTED_PATH")"
  HASH_VALUE="$(echo "$HASH_OUTPUT" | awk '{print $1}')"
  printf '%s\n' "$HASH_OUTPUT" > "$ENCRYPTED_PATH.sha256"
fi

echo ""
echo "Secure submission created."
echo "  Artifact : $ENCRYPTED_PATH"
if [[ -n "$HASH_VALUE" ]]; then
  echo "  Checksum : SHA-256 $HASH_VALUE (stored at $ENCRYPTED_PATH.sha256)"
fi

echo ""
echo "Next steps:"
echo "  1. Upload the secure submission file to Coursera."
if [[ -n "$HASH_VALUE" ]]; then
  echo "  2. Provide the SHA-256 checksum if the platform requests verification."
  echo "  3. Keep a local copy of the plaintext results for your records."
else
  echo "  2. Keep a local copy of the plaintext results for your records."
fi
