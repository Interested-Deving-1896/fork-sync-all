# gitlab-ci-eco.yml.tpl — KEcoLab GitLab CI pipeline template
#
# This template activates the KEcoLab energy measurement stub when the repo
# is hosted on GitLab (openos-project mirror chain).
#
# KEcoLab is KDE's remote energy measurement lab:
#   https://invent.kde.org/teams/eco/remote-eco-lab
#
# HOW TO ACTIVATE:
#   1. Copy this file to .gitlab-ci-eco.yml in your repo root
#   2. Include it from your main .gitlab-ci.yml:
#        include:
#          - local: .gitlab-ci-eco.yml
#   3. Write KdeEcoTest scripts in tests/eco/ (see KECO_TEST_DIR below)
#   4. Set the CI variables listed in the "variables" section
#   5. Submit your repo to KEcoLab:
#        https://invent.kde.org/teams/eco/remote-eco-lab/-/issues/new
#
# WHAT KECO_LAB MEASURES:
#   - Actual watt-hours consumed per scripted use case
#   - Measured via physical power meter (Yokogawa WT310E or similar)
#   - Connected to KDE's test hardware at their infrastructure
#   - Results published as energy consumption report
#
# WHAT THIS TEMPLATE DOES (without KEcoLab hardware):
#   - Runs the CI-measurable eco-audit (green hosting, Blue Angel checklist)
#   - Generates eco-audit.md report
#   - Stubs the energy measurement job with setup instructions
#   - Activates automatically when KECO_LAB_TOKEN is set (KEcoLab submission)
#
# VARIABLES TO SET IN GITLAB CI/CD SETTINGS:
#   KECO_LAB_TOKEN    — API token from KEcoLab (set after lab submission approval)
#   KECO_PROJECT_ID   — Your KEcoLab project ID (assigned by KEcoLab team)
#   GH_TOKEN          — GitHub token (for green hosting check)

variables:
  KECO_TEST_DIR: "tests/eco"
  KECO_LAB_URL: "https://invent.kde.org/teams/eco/remote-eco-lab"
  ECO_REPORT_PATH: "eco-audit.md"

stages:
  - eco-audit
  - eco-measure   # only runs with KEcoLab hardware

# ── Stage 1: CI-measurable eco audit ─────────────────────────────────────────
eco:audit:
  stage: eco-audit
  image: ubuntu:22.04
  rules:
    - if: '$CI_PIPELINE_SOURCE == "schedule"'
    - if: '$CI_PIPELINE_SOURCE == "web"'
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
      changes:
        - scripts/eco/**
        - .gitlab-ci-eco.yml
  before_script:
    - apt-get update -qq && apt-get install -y curl python3 git --quiet
  script:
    - bash scripts/eco/eco-audit.sh
  artifacts:
    paths:
      - DOCS/generated/eco-audit.md
      - /tmp/eco-audit.json
    expire_in: 90 days
    reports:
      # Expose eco-audit.md as a merge request widget
      dotenv: /tmp/eco-audit-env.txt

# ── Stage 2: KEcoLab energy measurement (stub — requires physical hardware) ───
eco:measure:
  stage: eco-measure
  image: ubuntu:22.04
  rules:
    # Only runs when KECO_LAB_TOKEN is set (KEcoLab submission approved)
    - if: '$KECO_LAB_TOKEN != null && $KECO_LAB_TOKEN != ""'
  needs: [eco:audit]
  script:
    - |
      echo "=== KEcoLab Energy Measurement ==="
      echo ""
      echo "KECO_LAB_TOKEN is set — attempting KEcoLab submission."
      echo ""

      # Check if KdeEcoTest scripts exist
      if [[ ! -d "${KECO_TEST_DIR}" ]]; then
        echo "ERROR: ${KECO_TEST_DIR}/ not found."
        echo "Create KdeEcoTest scripts before submitting to KEcoLab."
        echo "Reference: https://invent.kde.org/teams/eco/feep/-/tree/master/tools/KdeEcoTest"
        exit 1
      fi

      echo "KdeEcoTest scripts found in ${KECO_TEST_DIR}/"
      ls -la "${KECO_TEST_DIR}/"

      # Submit to KEcoLab API
      # The KEcoLab API accepts a tarball of test scripts + metadata
      # and queues them for execution on the physical test hardware.
      SUBMISSION=$(curl -sf \
        -H "Authorization: Bearer ${KECO_LAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
          \"project_id\": \"${KECO_PROJECT_ID:-}\",
          \"repo_url\": \"${CI_PROJECT_URL}\",
          \"commit\": \"${CI_COMMIT_SHA}\",
          \"test_dir\": \"${KECO_TEST_DIR}\",
          \"contact\": \"${GITLAB_USER_EMAIL:-}\"
        }" \
        "${KECO_LAB_URL}/api/submit" 2>/dev/null) || {
          echo "KEcoLab API unreachable or submission failed."
          echo "Submit manually: ${KECO_LAB_URL}/-/issues/new"
          exit 0
        }

      echo "Submission response: ${SUBMISSION}"
      echo "Check results at: ${KECO_LAB_URL}"

  allow_failure: true  # Don't block pipeline if KEcoLab is unavailable

# ── Stub job: shown when KECO_LAB_TOKEN is not set ────────────────────────────
eco:measure:stub:
  stage: eco-measure
  image: alpine:latest
  rules:
    - if: '$KECO_LAB_TOKEN == null || $KECO_LAB_TOKEN == ""'
  script:
    - |
      echo "=== KEcoLab Energy Measurement — STUB ==="
      echo ""
      echo "Physical energy measurement is not yet configured."
      echo ""
      echo "To activate:"
      echo "  1. Write KdeEcoTest scripts in ${KECO_TEST_DIR}/"
      echo "     Reference: https://invent.kde.org/teams/eco/feep/-/tree/master/tools/KdeEcoTest"
      echo ""
      echo "  2. Submit your project to KEcoLab:"
      echo "     ${KECO_LAB_URL}/-/issues/new"
      echo ""
      echo "  3. Once approved, set KECO_LAB_TOKEN in GitLab CI/CD variables"
      echo "     (Settings → CI/CD → Variables)"
      echo ""
      echo "  4. The eco:measure job will activate automatically."
      echo ""
      echo "Resources:"
      echo "  KDE Eco:        https://eco.kde.org/"
      echo "  KEcoLab:        ${KECO_LAB_URL}"
      echo "  Blue Angel:     https://www.blauer-engel.de/en/certification/criteria"
      echo "  Handbook:       https://eco.kde.org/be4foss-handbook"
  allow_failure: true
