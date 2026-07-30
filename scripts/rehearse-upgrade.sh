#!/bin/sh
# END-TO-END UPGRADE REHEARSAL against a REAL previously-published binary.
#
#   scripts/rehearse-upgrade.sh <path-to-old-uc> [<path-to-new-cli.js>]
#   scripts/rehearse-upgrade.sh "$(command -v uc)"
#
# Builds a realistic existing project with the OLD binary — two bound rows, a
# verified ledger, and one row minted to a signed FRESH proof in simulated
# trusted CI — then upgrades the binary and asserts that nothing an existing
# project depends on moved. Finally it crosses the 0.6.0 ledger boundary on
# purpose and checks that the failure is closed and reversible.
#
# The hermetic parts of this run on every build as tests
# (tests/release/upgrade-contract-*.test.ts, ledger-migration.test.ts,
# proof-survives-upgrade.test.ts). This script is the wider rehearsal: it needs
# an actual old binary, so it is run by hand at release time, and what it finds
# is what the release's migration note reports.
set -u

OLD="${1:-}"
if [ -z "$OLD" ] || [ ! -x "$OLD" ]; then
  echo "usage: $0 <path-to-old-uc> [<path-to-new-cli.js>]" >&2
  exit 2
fi
REPO=$(cd "$(dirname "$0")/.." && pwd)
NEW="node ${2:-$REPO/packages/cli/dist/index.js}"

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/keys" "$BASE/proj"
cp -R "$REPO/tests/fixtures/backcompat/src" "$BASE/proj/"
cp -R "$REPO/tests/fixtures/backcompat/use-cases" "$BASE/proj/"
cp "$REPO/tests/fixtures/backcompat/use-cases.yml" "$BASE/proj/"
git -C "$BASE/proj" init -q .
git -C "$BASE/proj" add -A
git -C "$BASE/proj" commit -qm "existing project"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected [$3] got [$2]"; fi; }

KEY="$BASE/keys/ci-signing-key.pub.pem"
status_of() {
  eval "$1" scan --repo "$BASE/proj" --public-key "$KEY" --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = [x for x in d['data']['status']['rows'] if x['row_id'] == '$2']
print(r[0]['status'] if r else 'MISSING')"
}
hashes_of() {
  eval "$1" scan --repo "$BASE/proj" --public-key "$KEY" --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
H = ('row_hash','current_binding_set_hash','verification_policy_hash','approval_policy_hash','local_status','status')
print(json.dumps([[x['row_id']] + [x.get(k) for k in H] for x in d['data']['status']['rows']], sort_keys=True))"
}

echo "=== 1. Build the project with the OLD binary ($("$OLD" --version)) ==="
"$OLD" bind --repo "$BASE/proj" --row checkout.apply_coupon --file src/coupon.js --mode explicit --register-existing >/dev/null 2>&1
"$OLD" bind --repo "$BASE/proj" --row checkout.refund_order --file src/refund.js --mode explicit --register-existing >/dev/null 2>&1
"$OLD" verify --repo "$BASE/proj" --all --out "$BASE/proj/.use-cases/verification-results.jsonl" >/dev/null 2>&1
"$OLD" keygen --out "$BASE/keys" --ci github >/dev/null 2>&1
UCM_CI_SIGNING_KEY=$(cat "$BASE/keys/ci-signing-key.pem"); export UCM_CI_SIGNING_KEY
GITHUB_ACTIONS=true GITHUB_REPOSITORY=acme/proj GITHUB_RUN_ID=1 \
GITHUB_SHA=$(git -C "$BASE/proj" rev-parse HEAD) \
  "$OLD" prove --repo "$BASE/proj" --row checkout.apply_coupon --trusted-ci --append \
    --signing-key-env UCM_CI_SIGNING_KEY --public-key "$KEY" \
    --verification-results "$BASE/proj/.use-cases/verification-results.jsonl" >/dev/null 2>&1
git -C "$BASE/proj" add -A && git -C "$BASE/proj" commit -qm "bound + proven with the old version"

OLD_COUPON=$(status_of "$OLD" checkout.apply_coupon)
OLD_REFUND=$(status_of "$OLD" checkout.refund_order)
OLD_HASHES=$(hashes_of "$OLD")
"$OLD" scan --repo "$BASE/proj" --public-key "$KEY" --gate >/dev/null 2>&1; OLD_GATE=$?
echo "  baseline: apply_coupon=$OLD_COUPON refund_order=$OLD_REFUND gate=exit $OLD_GATE"

echo ""
echo "=== 2. Upgrade the binary. Change NOTHING else. ==="
NEW_COUPON=$(status_of "$NEW" checkout.apply_coupon)
NEW_REFUND=$(status_of "$NEW" checkout.refund_order)
NEW_HASHES=$(hashes_of "$NEW")
eval "$NEW" scan --repo "$BASE/proj" --public-key "$KEY" --gate >/dev/null 2>&1; NEW_GATE=$?
check "signed FRESH row survives the upgrade"          "$NEW_COUPON" "$OLD_COUPON"
check "unsigned row survives the upgrade"              "$NEW_REFUND" "$OLD_REFUND"
check "release gate exit code unchanged"               "$NEW_GATE"   "$OLD_GATE"
check "every row/binding/policy hash is bit-identical" "$NEW_HASHES" "$OLD_HASHES"
# Vacuity guards: comparing two empty strings passes and proves nothing.
if [ "$OLD_COUPON" = "FRESH" ]; then
  ok "the baseline really was signed FRESH"
else
  bad "baseline was [$OLD_COUPON], not FRESH — the checks above prove nothing"
fi
case "$OLD_HASHES" in
  *sha256:*) ok "the hash comparison read real hashes" ;;
  *) bad "the hash comparison read nothing — it proves nothing" ;;
esac

echo ""
echo "=== 3. Carry on as before (no rebind). The old binary must still read it. ==="
eval "$NEW" verify --repo "$BASE/proj" --all >/dev/null 2>&1
LEDGER_ERRS=$("$OLD" scan --repo "$BASE/proj" --public-key "$KEY" --json 2>/dev/null | python3 -c "
import sys, json; print(len(json.load(sys.stdin)['data']['status']['integrity_errors']))")
check "a staggered rollout is safe until rebind is used" "$LEDGER_ERRS" "0"
git -C "$BASE/proj" add -A && git -C "$BASE/proj" commit -qm "daily loop on the new version"

echo ""
echo "=== 4. Cross the boundary on purpose: rebind ==="
eval "$NEW" rebind --repo "$BASE/proj" --row checkout.refund_order --file src/refund.js --mode explicit --start-line 1 --end-line 2 >/dev/null 2>&1
git -C "$BASE/proj" add -A && git -C "$BASE/proj" commit -qm "re-point a binding with the new version"
"$OLD" scan --repo "$BASE/proj" --public-key "$KEY" >/dev/null 2>&1; OLD_AFTER=$?
eval "$NEW" scan --repo "$BASE/proj" --public-key "$KEY" >/dev/null 2>&1; NEW_AFTER=$?
check "the old binary now fails closed on this workspace" "$OLD_AFTER" "4"
check "the new binary is unaffected"                      "$NEW_AFTER" "0"
check "an untouched row keeps its signed proof"           "$(status_of "$NEW" checkout.apply_coupon)" "FRESH"

echo ""
echo "=== 5. Rollback: a stranded old binary is harmless, and revert restores it ==="
BEFORE=$(shasum "$BASE/proj/.use-cases/bindings.jsonl" | cut -d' ' -f1)
"$OLD" verify --repo "$BASE/proj" --all >/dev/null 2>&1
"$OLD" bind --repo "$BASE/proj" --row checkout.apply_coupon --file src/coupon.js --mode explicit --register-existing >/dev/null 2>&1
AFTER=$(shasum "$BASE/proj/.use-cases/bindings.jsonl" | cut -d' ' -f1)
check "a stranded old binary cannot corrupt the ledger" "$AFTER" "$BEFORE"
git -C "$BASE/proj" revert --no-edit HEAD >/dev/null 2>&1
"$OLD" scan --repo "$BASE/proj" --public-key "$KEY" >/dev/null 2>&1; REVERTED=$?
check "git revert restores old-binary readability"      "$REVERTED" "0"
check "and the signed proof is still intact"            "$(status_of "$OLD" checkout.apply_coupon)" "FRESH"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
