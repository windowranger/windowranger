#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
script_name="${0:t}"
mode="--quick"
base_ref=""
head_ref="HEAD"

usage() {
    print "Usage: $script_name [--quick|--full] [--base REF] [--head REF]"
    print ""
    print -- "--quick  Run release/tooling checks and non-hosted tests. A bookkeeping-only diff may reuse a matching successful test receipt."
    print -- "--full   Also run static analysis, build unsigned Release, and verify both DMGs."
}

while (( $# > 0 )); do
    case "$1" in
        --quick|--full)
            mode="$1"
            ;;
        --base)
            (( $# >= 2 )) || { print -u2 "--base requires a ref"; exit 2; }
            base_ref="$2"
            shift
            ;;
        --head)
            (( $# >= 2 )) || { print -u2 "--head requires a ref"; exit 2; }
            head_ref="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
    shift
done

[[ "$mode" == "--quick" || -z "$base_ref" ]] || {
    print -u2 "--base is only supported with --quick. Full verification never skips app checks."
    exit 2
}

command -v xcodegen >/dev/null || {
    print -u2 "XcodeGen is required. Install it before running local verification."
    exit 1
}
command -v xcodebuild >/dev/null || {
    print -u2 "xcodebuild is required. Install/select Xcode before running local verification."
    exit 1
}

cd "$repository_root"

print "Checking shell syntax..."
zsh -n scripts/*.sh .githooks/*

print "Testing verification scope and release tooling..."
python3 scripts/test_verification_scope.py
python3 scripts/test_release.py
python3 scripts/test_release_channels.py
python3 scripts/test_stage_release_feed.py
python3 scripts/test_appcast.py

print "Verifying the release build-number ledger..."
./scripts/verify-release-build-registry.sh

print "Verifying the Sparkle feed ordering and failure workflow..."
./scripts/verify-sparkle-feed-workflow.sh

print "Verifying the Stable Homebrew Cask workflow..."
./scripts/verify-homebrew-cask-workflow.sh

print "Generating the Xcode project..."
xcodegen generate

print "Verifying the non-hosted test boundary..."
./scripts/verify-test-isolation.sh

reuse_quick_tests=false
receipt=""
if [[ "$mode" == "--quick" ]]; then
    requested_head="$(git rev-parse --verify "${head_ref}^{commit}" 2>/dev/null || true)"
    checked_out_head="$(git rev-parse HEAD)"
    if [[ -n "$requested_head" && "$requested_head" == "$checked_out_head" && -z "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
        git_common_dir="$(git rev-parse --git-common-dir)"
        [[ "$git_common_dir" == /* ]] || git_common_dir="$repository_root/$git_common_dir"
        receipt="$git_common_dir/windowranger-quick-verification.json"
    else
        print "Quick-check receipt reuse is disabled because the checkout is dirty or --head is not the checked-out commit."
    fi
fi
if [[ "$mode" == "--quick" && -n "$base_ref" ]]; then
    verification_scope="$(python3 scripts/verification-scope.py --repository-root "$repository_root" scope --base "$base_ref" --head "$head_ref")"
    if [[ "$verification_scope" == "bookkeeping" ]]; then
        if [[ -n "$receipt" ]] && python3 scripts/verification-scope.py --repository-root "$repository_root" receipt-valid --commit "$head_ref" --receipt "$receipt"; then
            reuse_quick_tests=true
            print "Reusing the matching successful non-bookkeeping quick-check receipt."
        else
            print "No matching successful quick-check receipt; running the non-hosted suite."
        fi
    fi
fi

if [[ "$reuse_quick_tests" == false ]]; then
    print "Running the complete non-hosted test suite..."
    xcodebuild \
        -project WindowRanger.xcodeproj \
        -scheme WindowRanger \
        -configuration Debug \
        -destination 'platform=macOS' \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        test
    if [[ "$mode" == "--quick" && -n "$receipt" && "$(git rev-parse HEAD)" == "$requested_head" && -z "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
        python3 scripts/verification-scope.py --repository-root "$repository_root" record-success --commit "$head_ref" --receipt "$receipt" --verification-status passed
    fi
fi

if [[ "$mode" == "--quick" ]]; then
    print "Local quick verification passed."
    exit 0
fi

print "Running Release static analysis..."
xcodebuild \
    -project WindowRanger.xcodeproj \
    -scheme WindowRanger \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath .build/local-ci-derived-data \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    analyze

print "Building the unsigned Release configuration in canonical DerivedData..."
xcodebuild \
    -project WindowRanger.xcodeproj \
    -scheme WindowRanger \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath .build/local-ci-derived-data \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

release_build_directory="$(
    xcodebuild \
        -project WindowRanger.xcodeproj \
        -scheme WindowRanger \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath .build/local-ci-derived-data \
        -showBuildSettings \
    | /usr/bin/awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / && !found { print $2; found = 1 }'
)"
release_app="$release_build_directory/WindowRanger.app"
[[ -d "$release_app" ]] || {
    print -u2 "Unsigned Release app was not found in canonical DerivedData: $release_app"
    exit 1
}

print "Building and verifying unsigned Stable/Beta DMG smoke packages..."
./scripts/install-dmg-tools.sh
package_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/windowranger-local-ci.XXXXXX")"
cleanup() {
    [[ "$package_root" == "${TMPDIR:-/tmp}/windowranger-local-ci."* ]] || return
    /bin/rm -rf "$package_root"
}
trap cleanup EXIT INT TERM

stable_dmg="$package_root/WindowRanger-unsigned-stable.dmg"
beta_dmg="$package_root/WindowRanger-unsigned-beta.dmg"
./scripts/build-dmg.sh --app "$release_app" --channel stable --output "$stable_dmg"
./scripts/build-dmg.sh --app "$release_app" --channel beta --output "$beta_dmg"
./scripts/verify-dmg.sh --dmg "$stable_dmg"
./scripts/verify-dmg.sh --dmg "$beta_dmg"

print "Local full verification passed."
