#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly REPOSITORY_ROOT=${SCRIPT_DIR:h}
readonly DISTRIBUTION_DIR="${REPOSITORY_ROOT}/Distribution"

fail() {
    print -u2 -- "error: $*"
    exit 1
}

usage() {
    print -u2 -- "Usage: Scripts/package-release.zsh <ad-hoc|notarized> <version>"
    exit 64
}

(( $# == 2 )) || usage
readonly RELEASE_MODE=$1
readonly RELEASE_VERSION=$2

case "${RELEASE_MODE}" in
    ad-hoc|notarized) ;;
    *) usage ;;
esac

print -r -- "${RELEASE_VERSION}" \
    | /usr/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
    || fail "version must use only letters, digits, dots, underscores, and hyphens"

for release_tool in xcodebuild codesign otool lipo strip zip unzip shasum; do
    command -v "${release_tool}" >/dev/null \
        || fail "required tool '${release_tool}' was not found"
done

readonly OUTPUT_BASENAME="ergometal-macos-arm64-${RELEASE_VERSION}-${RELEASE_MODE}"
readonly OUTPUT_ZIP="${DISTRIBUTION_DIR}/${OUTPUT_BASENAME}.zip"
readonly OUTPUT_CHECKSUM="${OUTPUT_ZIP}.sha256"
[[ ! -e "${OUTPUT_ZIP}" && ! -e "${OUTPUT_CHECKSUM}" ]] \
    || fail "release output already exists: ${OUTPUT_BASENAME}"

DEVELOPER_IDENTITY=""
NOTARY_PROFILE=""
if [[ "${RELEASE_MODE}" == notarized ]]; then
    command -v xcrun >/dev/null || fail "required tool 'xcrun' was not found"
    command -v security >/dev/null || fail "required tool 'security' was not found"
    command -v spctl >/dev/null || fail "required tool 'spctl' was not found"

    DEVELOPER_IDENTITY=${ERGOMETAL_DEVELOPER_ID_APPLICATION:-}
    if [[ -z "${DEVELOPER_IDENTITY}" ]]; then
        developer_identities=()
        while IFS= read -r candidate; do
            [[ -n "${candidate}" ]] && developer_identities+=("${candidate}")
        done < <(/usr/bin/security find-identity -v -p codesigning \
            | /usr/bin/sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')

        (( ${#developer_identities[@]} > 0 )) \
            || fail "no Developer ID Application identity is installed"
        (( ${#developer_identities[@]} == 1 )) \
            || fail "multiple Developer ID Application identities found; set ERGOMETAL_DEVELOPER_ID_APPLICATION"
        DEVELOPER_IDENTITY=${developer_identities[1]}
    fi

    [[ "${DEVELOPER_IDENTITY}" == "Developer ID Application: "* ]] \
        || fail "ERGOMETAL_DEVELOPER_ID_APPLICATION must name a Developer ID Application identity"
    /usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/grep -F -- "\"${DEVELOPER_IDENTITY}\"" >/dev/null \
        || fail "Developer ID identity is not available in the current keychain"
    NOTARY_PROFILE=${ERGOMETAL_NOTARY_PROFILE:-ergometal-notary}
fi

readonly TEMPORARY_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ergometal-release.XXXXXX")
trap '/bin/rm -rf -- "${TEMPORARY_ROOT}"' EXIT INT TERM

readonly DERIVED_DATA="${TEMPORARY_ROOT}/DerivedData"
readonly STAGING_DIR="${TEMPORARY_ROOT}/staging"
readonly VERIFY_DIR="${TEMPORARY_ROOT}/verify"
readonly STAGED_BINARY="${STAGING_DIR}/ergometal"
readonly TEMPORARY_ZIP="${TEMPORARY_ROOT}/ergometal.zip"

/bin/mkdir -p "${STAGING_DIR}" "${VERIFY_DIR}"

print -- "Building the standalone Release executable"
xcodebuild \
    -project "${REPOSITORY_ROOT}/MetalErgoMiner.xcodeproj" \
    -scheme MetalErgoMiner \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO \
    build

readonly BUILT_BINARY="${DERIVED_DATA}/Build/Products/Release/ergometal"
[[ -f "${BUILT_BINARY}" ]] || fail "Release build did not produce ergometal"
/bin/cp "${BUILT_BINARY}" "${STAGED_BINARY}"
/bin/chmod 755 "${STAGED_BINARY}"
/usr/bin/strip -S -x "${STAGED_BINARY}"

if /usr/bin/otool -l "${STAGED_BINARY}" \
    | /usr/bin/awk '$1 == "segname" && $2 == "__DWARF" { found = 1 } END { exit !found }'; then
    fail "release executable still contains a __DWARF segment after stripping"
fi

if [[ "${RELEASE_MODE}" == ad-hoc ]]; then
    print -- "Applying an ad-hoc signature"
    /usr/bin/codesign --force --sign - --timestamp=none "${STAGED_BINARY}"
else
    print -- "Signing with ${DEVELOPER_IDENTITY}"
    /usr/bin/codesign \
        --force \
        --sign "${DEVELOPER_IDENTITY}" \
        --options runtime \
        --timestamp \
        "${STAGED_BINARY}"
fi

/usr/bin/codesign --verify --strict --verbose=2 "${STAGED_BINARY}"

if [[ "${RELEASE_MODE}" == notarized ]]; then
    /usr/bin/codesign -d --verbose=4 "${STAGED_BINARY}" 2>&1 \
        | /usr/bin/grep -E '^CodeDirectory .*flags=.*\(runtime\)' >/dev/null \
        || fail "Developer ID signature does not enable Hardened Runtime"
fi

[[ "$(/usr/bin/lipo -archs "${STAGED_BINARY}")" == arm64 ]] \
    || fail "release executable is not arm64-only"

/usr/bin/otool -l "${STAGED_BINARY}" \
    | /usr/bin/awk '$1 == "sectname" && $2 == "__metallib" { found = 1 } END { exit !found }' \
    || fail "release executable does not contain __TEXT,__metallib"

while IFS= read -r dependency; do
    case "${dependency}" in
        /System/Library/*|/usr/lib/*) ;;
        *) fail "non-system runtime dependency found: ${dependency}" ;;
    esac
done < <(/usr/bin/otool -L "${STAGED_BINARY}" | /usr/bin/awk 'NR > 1 { print $1 }')

print -- "Creating the one-file ZIP archive"
(
    cd "${STAGING_DIR}"
    /usr/bin/zip -X -q "${TEMPORARY_ZIP}" ergometal
)

[[ "$(/usr/bin/unzip -Z1 "${TEMPORARY_ZIP}")" == ergometal ]] \
    || fail "ZIP archive must contain exactly one root entry named ergometal"
/usr/bin/unzip -q "${TEMPORARY_ZIP}" -d "${VERIFY_DIR}"
[[ -x "${VERIFY_DIR}/ergometal" ]] || fail "ZIP archive did not preserve executable permissions"
/usr/bin/codesign --verify --strict --verbose=2 "${VERIFY_DIR}/ergometal"

print -- "Running an isolated Metal smoke benchmark"
"${VERIFY_DIR}/ergometal" benchmark \
    --duration 1 \
    --height 614399 \
    --table-size 1024 \
    --batch-nonces 1024 \
    --autotune off \
    --build-chunk-elements 1024 \
    --search-pipeline-depth 2 \
    --build-pipeline-depth 2 \
    --prebuild off \
    --json >/dev/null

if [[ "${RELEASE_MODE}" == notarized ]]; then
    readonly NOTARY_RESULT="${TEMPORARY_ROOT}/notary-result.json"

    print -- "Submitting the ZIP archive to Apple's notary service"
    if ! xcrun notarytool submit "${TEMPORARY_ZIP}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait \
        --output-format json >"${NOTARY_RESULT}"; then
        fail "notary submission failed; verify the '${NOTARY_PROFILE}' keychain profile"
    fi

    notary_status=$(/usr/bin/plutil -extract status raw -o - "${NOTARY_RESULT}")
    notary_id=$(/usr/bin/plutil -extract id raw -o - "${NOTARY_RESULT}")
    if [[ "${notary_status}" != Accepted ]]; then
        xcrun notarytool log "${notary_id}" --keychain-profile "${NOTARY_PROFILE}" || true
        fail "Apple notarization status is ${notary_status}"
    fi

    print -- "Notarization accepted as ${notary_id}; verifying Gatekeeper assessment"
    gatekeeper_accepted=false
    for attempt in {1..60}; do
        gatekeeper_output=$(/usr/sbin/spctl -a -t exec -vv "${VERIFY_DIR}/ergometal" 2>&1) \
            && gatekeeper_status=0 \
            || gatekeeper_status=$?
        print -u2 -- "${gatekeeper_output}"

        # A raw Mach-O command-line tool is not an app bundle, so spctl exits
        # non-zero even after it retrieves the ticket. The second result is
        # distinct from `source=Unnotarized Developer ID` and confirms that
        # Gatekeeper recognizes the notarized code as valid.
        if (( gatekeeper_status == 0 )) \
            || [[ "${gatekeeper_output}" == *"the code is valid but does not seem to be an app"* ]]; then
            gatekeeper_accepted=true
            break
        fi
        if (( attempt < 60 )); then
            print -- "Gatekeeper ticket is not available yet (attempt ${attempt}/60); retrying in 10 seconds"
            /bin/sleep 10
        fi
    done
    [[ "${gatekeeper_accepted}" == true ]] \
        || fail "Gatekeeper did not accept the notarized executable"
fi

/bin/mkdir -p "${DISTRIBUTION_DIR}"
/bin/mv "${TEMPORARY_ZIP}" "${OUTPUT_ZIP}"
(
    cd "${DISTRIBUTION_DIR}"
    /usr/bin/shasum -a 256 "${OUTPUT_BASENAME}.zip" >"${OUTPUT_BASENAME}.zip.sha256"
)

print -- "Created ${OUTPUT_ZIP}"
print -- "Created ${OUTPUT_CHECKSUM}"
