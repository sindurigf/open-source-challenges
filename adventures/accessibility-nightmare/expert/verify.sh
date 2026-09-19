#!/usr/bin/env bash
set -euo pipefail

# Load shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../../lib/scripts/loader.sh"

set_tracking_context "accessibility-nightmare" "expert" "" "" ""

OBJECTIVE="
- Have the gate audit every step a customer moves through, not only the homepage.
- Find the navigation barrier that automated scanning has never reported.
- Fix it and have the gate verify the fix holds.
- Produce a report proving each customer journey step was audited and passes."

DOCS_URL="https://offon.dev/adventures/accessibility-nightmare/levels/expert"

EXPECTED_DEPENDENCIES="@axe-core/playwright @guidepup/virtual-screen-reader @playwright/test @vitejs/plugin-react react react-dom vite"

print_header \
  'The Accessibility Nightmare' \
  'The Compliance Engine' \
  'Verification'

TESTS_PASSED=0
TESTS_FAILED=0
FAILED_CHECKS=()

check_prerequisites node npm npx jq

print_sub_header "Running verification checks..."

# 1. Dependencies unchanged -----------------------------------------------
check_npm_dependencies \
  "package.json" \
  "${EXPECTED_DEPENDENCIES}" \
  "The app dependencies are unchanged" \
  "This level is about the check, not the app. The dependency set is fixed. If you added or removed a library, revert the change."

# 2. The scan is green on the product as it stands -------------------------
FAILURES_BEFORE_SCAN=${TESTS_FAILED}

check_playwright_tests "@scan" \
  "The accessibility scan passes" \
  "Your scanner tests are reporting a violation. Read what axe returned: it names the rule and the element it found."

# 3. The scan actually reaches the whole journey ---------------------------
#
# A green suite proves nothing about where it looked. Plant a fault on the last
# step of the journey and require the suite to go red. A gate that still passes
# never opened that page.
#
# Only meaningful while the scan is otherwise green: against an already-failing
# suite a red result says nothing about coverage.

if [[ ${TESTS_FAILED} -ne ${FAILURES_BEFORE_SCAN} ]]; then
  print_test_section "Checking The accessibility scan covers every step a customer moves through..."
  print_error_indent "The accessibility scan covers every step a customer moves through"
  print_hint "Coverage cannot be measured while the scan is failing. Resolve the violation above, then run this again."
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_CHECKS+=("scan_coverage_unmeasured")
  print_new_line
else
  PAYMENT="${SCRIPT_DIR}/src/pages/Payment.jsx"
  PAYMENT_BAK="${SCRIPT_DIR}/src/pages/.Payment.jsx.orig"

  restore_payment() {
    if [[ -f "${PAYMENT_BAK}" ]]; then
      mv -f "${PAYMENT_BAK}" "${PAYMENT}"
    fi
  }
  trap restore_payment EXIT

  cp "${PAYMENT}" "${PAYMENT_BAK}" || {
    echo "could not read ${PAYMENT}" >&2
    exit 1
  }

  python3 - "${PAYMENT}" <<'PY'
import sys
path = sys.argv[1]
source = open(path).read()
anchor = '<h1>Payment</h1>'
if anchor not in source:
    sys.exit('anchor not found')
# An image with no alt text: axe reports image-alt at critical impact.
open(path, 'w').write(
    source.replace(anchor, anchor + '\n            <img src="/accepted-cards.png" />', 1)
)
PY

  if ! grep -q 'accepted-cards.png' "${PAYMENT}"; then
    restore_payment
    echo "could not plant the coverage probe in ${PAYMENT}; leave that file unmodified" >&2
    exit 1
  fi

  # Vite needs a moment to rebuild before the suite reloads the page.
  sleep 2

  check_playwright_tests_detect "@scan" \
    "The accessibility scan covers every step a customer moves through" \
    "A fault was planted on one of the four pages a customer passes through, and your scan stayed green. The gate was written when the homepage was the only page. Which of the others does it open?"

  restore_payment
  trap - EXIT
  sleep 1
fi

# 4. Route transitions are announced --------------------------------------
check_playwright_tests "@transition" \
  "The gate catches the navigation barrier that the scanner never reported" \
  "Nothing here is wrong in the markup, so the scanner has nothing to report. Move through the app the way someone who cannot see it would, and pay attention to what arrives after the address changes."

# 5. Compliance report documenting what was audited -----------------------

print_test_section "Checking compliance report..."

REPORT="${SCRIPT_DIR}/compliance-report.json"

if [[ ! -f "${REPORT}" ]]; then
  print_error_indent "Compliance report exists"
  print_hint "The run left no record behind. Playwright decides what to emit from its reporter configuration, and by default that is terminal output only."
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_CHECKS+=("compliance_report_missing")
else
  HAS_ANNOTATION=$(jq -r '
    [.. | objects | select(has("annotations")) | .annotations[]
       | select(.type == "route-announcement")] | length
  ' "${REPORT}" 2>/dev/null || echo "0")

  if [[ "${HAS_ANNOTATION}" -gt 0 ]]; then
    print_success_indent "Compliance report documents the route announcements that were verified"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    print_error_indent "Compliance report documents the route announcements that were verified"
    print_hint "The report records that the tests ran, but not what any of them set out to prove. A result with no claim attached is not evidence an auditor can use. Playwright lets a test annotate itself; the gate is looking for the type route-announcement."
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_CHECKS+=("compliance_report_annotation")
  fi
fi

print_new_line

# ==========================================================================
# Summary
# ==========================================================================

failed_checks_json="[]"
if [[ -n "${FAILED_CHECKS[*]:-}" ]]; then
  failed_checks_json=$(printf '%s\n' "${FAILED_CHECKS[@]}" | jq -R . | jq -s .)
fi

if [[ ${TESTS_FAILED} -gt 0 ]]; then
  track_verification_completed "failed" "${failed_checks_json}"
  print_verification_summary "accessibility-nightmare" "${DOCS_URL}" "${OBJECTIVE}"
  exit 1
fi

track_verification_completed "success" "${failed_checks_json}"

print_header "Test Results Summary"
print_success "✅ PASSED: All ${TESTS_PASSED} verification checks passed!"
print_new_line

check_submission_readiness "accessibility-nightmare" "expert"
