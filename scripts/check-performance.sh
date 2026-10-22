#!/usr/bin/env bash
set -euo pipefail

if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "CI records performance measurements without enforcing local speed limits."
  exit 0
fi

root="$(git rev-parse --show-toplevel)"
cd "$root"
export FOCUSNOTES_PERF_GATES=1

case "$(uname -s)" in
  Darwin)
    swift run CoreChecks --performance-only
    ;;
  MINGW*|MSYS*|CYGWIN*)
    cd windows
    dotnet restore CaptureApp.sln --locked-mode
    filter='Category=Perf'
    if [[ "${CAPTUREAPP_RUN_INTERACTIVE_TESTS:-}" == "1" ]]; then
      filter+='|FullyQualifiedName~I_ThousandCapturesRestoreByteIdenticalFormatsAndReportHoldTimes'
    else
      echo "Clipboard hold-time benchmark skipped; set CAPTUREAPP_RUN_INTERACTIVE_TESTS=1 on an interactive desktop to include it."
    fi
    export CAPTUREAPP_REQUIRE_OCR_MODELS=1
    dotnet test CaptureApp.sln -c Release --no-restore -m:1 --filter "$filter" --logger 'console;verbosity=detailed'
    ;;
  *)
    echo "Local performance gates require macOS or Windows." >&2
    exit 1
    ;;
esac
