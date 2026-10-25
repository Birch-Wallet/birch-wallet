#!/usr/bin/env bash
# Checks that Sparrow can import the labels Birch exports as an animated QR.
#
#   scripts/sparrow-labels-harness/run.sh [path to a Sparrow checkout]
#
# The Sparrow checkout defaults to ~/Source/sparrow. Set BIRCH_HARNESS_DESTINATION
# to run the Birch half on another simulator, and SPARROW_JAVA_HOME to pick the JDK
# that builds Sparrow (otherwise the installed JDK 25).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SPARROW="$(cd "${1:-$HOME/Source/sparrow}" && pwd)"
DESTINATION="${BIRCH_HARNESS_DESTINATION:-platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2}"

if [ ! -x "$SPARROW/gradlew" ]; then
  echo "No Sparrow checkout at $SPARROW" >&2
  exit 1
fi

# Sparrow only compiles against the drongo and lark commits it records
if git -C "$SPARROW" submodule status | grep -q '^[-+]'; then
  echo "Sparrow's submodules aren't at the commits it records. Run: git -C \"$SPARROW\" submodule update --init" >&2
  exit 1
fi

# Sparrow's Gradle runs on Java 17 to 25, and its code needs 22 or later
SPARROW_JAVA_HOME="${SPARROW_JAVA_HOME:-$(/usr/libexec/java_home -v 25 2>/dev/null || true)}"
if [ -z "$SPARROW_JAVA_HOME" ]; then
  echo "Building Sparrow needs JDK 25 (Gradle can't run on newer ones). Install it, or set SPARROW_JAVA_HOME." >&2
  exit 1
fi

OUT="$(mktemp -d -t birch-sparrow-labels)"
TEST_FILE="$SPARROW/src/test/java/com/sparrowwallet/sparrow/io/BirchLabelsQRImportTest.java"
RESOURCES="$SPARROW/src/test/resources/com/sparrowwallet/sparrow/io/birch"
REPORT="$SPARROW/build/test-results/test/TEST-com.sparrowwallet.sparrow.io.BirchLabelsQRImportTest.xml"

# Leave the Sparrow checkout as it was
cleanup() {
  rm -f "$TEST_FILE"
  rm -rf "$RESOURCES"
}
trap cleanup EXIT

echo "==> Birch: exporting labels the way Export QR does"
TEST_RUNNER_BIRCH_SPARROW_HARNESS_OUT="$OUT" xcodebuild test \
  -project "$ROOT/birch.xcodeproj" -scheme birch -destination "$DESTINATION" \
  -only-testing:birchTests/SparrowLabelsQRHarnessTests -parallel-testing-enabled NO -quiet
for size in small realistic; do
  if [ ! -f "$OUT/scenario-$size.json" ]; then
    echo "Birch wrote no scenario-$size.json to $OUT" >&2
    exit 1
  fi
done
echo "    Artifacts: $OUT"

echo "==> Sparrow: scanning the frames and importing the labels"
cp "$HERE/BirchLabelsQRImportTest.java" "$TEST_FILE"
mkdir -p "$RESOURCES"
cp -R "$OUT"/. "$RESOURCES"/
rm -f "$REPORT"

set +e
(cd "$SPARROW" && JAVA_HOME="$SPARROW_JAVA_HOME" ./gradlew :test --tests com.sparrowwallet.sparrow.io.BirchLabelsQRImportTest)
status=$?
set -e

echo
echo "==> Results"
if [ -f "$REPORT" ]; then
  python3 - "$REPORT" <<'EOF'
import sys
import xml.etree.ElementTree as ET

suite = ET.parse(sys.argv[1]).getroot()
for case in suite.iter("testcase"):
    failure = case.find("failure")
    print(("FAIL  " if failure is not None else "pass  ") + case.get("name"))
    if failure is not None:
        for line in (failure.get("message") or "").splitlines():
            print("      " + line)
out = suite.findtext("system-out") or ""
notes = [line for line in out.splitlines() if line.startswith("[")]
if notes:
    print()
    print("\n".join(notes))
EOF
else
  echo "No test report at $REPORT; see the Gradle output above."
fi
exit $status
