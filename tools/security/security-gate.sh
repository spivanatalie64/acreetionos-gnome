#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - Alpha-channel security gate
# ==============================================================================
#  Runs before an alpha-channel release is built:
#    1. Build/test suite (bash -n, Python unittest, cargo test)
#    2. Dependency trees compared against the latest public CVE feed (OSV.dev)
#    3. A PRIVATE issue is created containing the affected CVEs
#    4. Automated patching is applied (cargo update, npm audit fix)
#    5. The issue is commented with results, then temporarily closed with a
#       call for human review
#
#  Issue privacy: the gate refuses to create the issue on a public
#  repository; a local draft is produced for a private repo instead.
#
#  Usage: security-gate.sh [--skip-tests] [--no-patch] [--dry-run]
#  Env:   HORIZON_SECURITY_REPO   repo slug override (default: origin)
#         HORIZON_SECURITY_PUSH   push the auto-patch branch (default: no)
# ==============================================================================
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out_dir="${HORIZON_BUILD_DIR:-$root_dir/.horizon-build}/security"
skip_tests=false
no_patch=false
dry_run=false
case "${1:-}" in
    --skip-tests) skip_tests=true ;;
    --no-patch)   no_patch=true ;;
    --dry-run)    dry_run=true; no_patch=true ;;
    ''|--help|-h) printf 'Usage: %s [--skip-tests|--no-patch|--dry-run]\n' "$0"; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac
mkdir -p "$out_dir"
gate_stamp="$(date +%Y%m%d-%H%M%S)"
gate_log="$out_dir/gate-$gate_stamp.log"

exec > >(tee -a "$gate_log") 2>&1

fail() { printf 'error: security-gate: %s\n' "$*" >&2; exit 1; }
survey=()

# ── Phase 1: build/test suite ────────────────────────────────────────────────
echo "═══ Security gate 1/5: build tests ═══"
if ! "$skip_tests"; then
    test_status=''
    printf -- '==> bash -n on every first-party shell script\n'
    if find "$root_dir" -maxdepth 3 -name '*.sh' \
            ! -path '*/node_modules/*' ! -path '*/target/*' \
            -print0 2>/dev/null |
        xargs -0 -r -n1 bash -n; then
        survey+=("bash -n: OK")
    else
        test_status='FAIL (bash -n)'
    fi
    printf -- '==> python3 unittest (tests/)\n'
    if python3 -m unittest discover -s "$root_dir/tests" -p 'test_*.py' 2>&1 | tee "$out_dir/unittest.log"; then
        survey+=("unittest: OK")
    elif ! command -v python3 >/dev/null 2>&1; then
        survey+=("unittest: SKIPPED (python3 missing)")
    else
        test_status='FAIL (unittest)'
    fi
    printf -- '==> cargo test --workspace (freeman)\n'
    if (cd "$root_dir/tools/freeman" && cargo test --workspace 2>&1 |
            tee "$out_dir/cargo-test.log"); then
        survey+=("cargo test: OK")
    else
        test_status='FAIL (cargo test)'
    fi
    [[ -z "$test_status" ]] || { echo "⛔ Test phase failed: $test_status"; exit 1; }
else
    survey+=("build tests: skipped by flag")
fi

# ── Phase 2: dependency trees vs latest CVE releases ─────────────────────────
echo "═══ Security gate 2/5: dependency trees vs. CVE feed ═══"
npm_locks=()
while IFS= read -r lock; do
    npm_locks+=("$lock")
done < <(find "$root_dir" -maxdepth 3 -name 'package-lock.json' ! -path '*/node_modules/*')
findings_file="$out_dir/cve-findings.tsv"
if python3 "$root_dir/tools/security/osv_check.py" \
        "$root_dir/tools/freeman/Cargo.lock" "${npm_locks[@]}" > "$out_dir/findings.tsv.raw" &&
   ! head -n1 "$out_dir/findings.tsv.raw" | grep -q '^NO_CVE_FINDINGS'; then
    mv "$out_dir/findings.tsv.raw" "$findings_file"
    nfindings=$(wc -l < "$findings_file")
    survey+=("CVE findings: $nfindings")
    echo "    $nfindings affected package/CVE combinations - see $findings_file"
else
    : > "$findings_file"
    nfindings=0
    survey+=("CVE findings: none")
fi

# ── Phase 3: private issue draft with the CVEs ───────────────────────────────
echo "═══ Security gate 3/5: private CVE issue ═══"
issue_num=""
if [[ "$nfindings" -eq 0 ]]; then
    echo "    no CVEs found; no issue needed"
else
    body_file="$out_dir/CVE-issue-draft-$gate_stamp.md"
    {
        echo "## Latest CVEs in the dependency trees"
        echo
        echo "| ecosystem | package | installed | CVE refs | severity |"
        echo "|---|---|---|---|---|"
        awk -F'\t' '{printf "| %s | %s | %s | `%s` | %s |\n", $1, $2, $3, $4, $5}' "$findings_file"
        echo
        echo "## Build-test results"
        printf -- '- %s\n' "${survey[@]}"
        echo
        echo "Automated patching follows this issue; see the comment afterwards."
        echo "FINDINGS_DATA_SHA256: $(sha256sum "$findings_file" | cut -d' ' -f1)"
    } > "$body_file"

    private_repo_ok=$(gh repo view --json isPrivate -q .isPrivate 2>/dev/null || echo "")
    if [[ -n "$private_repo_ok" && "$private_repo_ok" != "true" ]]; then
        echo "warning: repository is not private; keeping the CVE draft as a local file only" >&2
        echo "Draft kept at: $body_file"
    elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && ! "$dry_run"; then
        gh label create security --color 'ff6699' --description 'Alpha security gate' 2>/dev/null || true
        repo_slug=$(gh repo view --json nameWithOwner -q .nameWithOwner)
        iss_url=$(HORIZON_SECURITY_REPO="$repo_slug" gh issue create \
            --title "Alpha security gate: CVE review ($gate_stamp)" \
            --body-file "$body_file" \
            --label 'security' \
            --repo "$repo_slug") || iss_url=""
        [[ -z "$iss_url" ]] && iss_num="" || iss_num="$(basename "$iss_url")"
        issue_num="$iss_num"
        echo "    private issue created: $iss_url (restraint: body stored offline too)"
    fi
fi

# ── Phase 4: automated patching ──────────────────────────────────────────────
echo "═══ Security gate 4/5: automated patching ═══"
remaining="?"
if [[ "$nfindings" -gt 0 && "$no_patch" != 1 ]]; then
    (cd "$root_dir/tools/freeman" && cargo update 2>&1 | tail -n 20) || true
    for lock in "${npm_locks[@]}"; do
        (cd "$(dirname "$lock")" && npm audit fix --package-lock-only 2>&1 | tail -n 10) || true
    done
    patch_changed=()
    while IFS= read -r path; do
        patch_changed+=("$path")
    done < <(git -C "$root_dir" status --porcelain -- 'tools/freeman/Cargo.lock' '**/package-lock.json' '*/package-lock.json' | awk '{print $2}')
    if (( ${#patch_changed[@]} > 0 )); then
        echo "    patched: ${patch_changed[*]}"
        patched_summary="$(git -C "$root_dir" diff --stat -- "${patch_changed[@]}" | tail -n 5)"
        if (cd "$root_dir/tools/freeman" && cargo test --workspace >>"$out_dir/cargo-test.log" 2>&1); then
            survey+=("post-patch cargo test: OK")
            if ! "$dry_run"; then
                branch="security/auto-patch-$(date +%Y%m%d)"
                git -C "$root_dir" switch -c "$branch" 2>/dev/null || true
                git -C "$root_dir" add -- "${patch_changed[@]}"
                git -C "$root_dir" commit -m \
                    "chore(security): auto-patch vulnerable dependency trees (alpha gate $gate_stamp)" \
                    -- "${patch_changed[@]}"
                [[ "${HORIZON_SECURITY_PUSH:-0}" == 1 ]] && git -C "$root_dir" push -u origin "$branch"
            fi
        else
            survey+=("post-patch cargo test: FAILED - lockfile changes reverted")
            git -C "$root_dir" checkout -- "${patch_changed[@]}" 2>/dev/null || true
        fi
    else
        patched_summary="(no lockfile changes apply automatically)"
    fi
    if python3 "$root_dir/tools/security/osv_check.py" \
            "$root_dir/tools/freeman/Cargo.lock" "${npm_locks[@]}" > "$out_dir/findings-post.tsv.raw" &&
       head -n1 "$out_dir/findings-post.tsv.raw" | grep -q '^NO_CVE_FINDINGS'; then
        remaining=0
        rm -f "$out_dir/findings-post.tsv.raw"
    else
        mv "$out_dir/findings-post.tsv.raw" "$out_dir/findings-post.tsv"
        remaining=$(wc -l < "$out_dir/findings-post.tsv")
    fi
    survey+=("remaining CVEs after patch: $remaining")
else
    survey+=("patching: skipped")
fi

# ── Phase 5: comment on the issue, then temporarily close for review ─────────
echo "═══ Security gate 5/5: issue comment + close for review ═══"
if [[ -n "$issue_num" && -n "${repo_slug:-}" ]]; then
    comment_file="$out_dir/gate-comment-$gate_stamp.md"
    {
        echo "## Automated patching results"
        printf -- '- %s\n' "${survey[@]}"
        [[ -z "$patched_summary" ]] || { echo; echo '```'; printf '%s\n' "$patched_summary"; echo '```'; }
        echo
        echo "Automated patch branch: \`security/auto-patch-*\`; review required."
    } > "$comment_file"
    gh issue comment "$issue_num" --body-file "$comment_file" --repo "$repo_slug"
    gh issue close "$issue_num" \
        --comment "Temporarily closed: dependency CVEs were auto-patched and results are in the comment above.

**Review requested.** Please verify the post-patch lockfile diff and remaining-CVE list; reopen if any patch is unsound. Alpha builds proceed at the reviewer's discretion." \
        --repo "$repo_slug"
else
    echo "    no remote issue to update (local draft under $out_dir has everything)"
fi
echo "==> Security gate complete. Log: $gate_log"

