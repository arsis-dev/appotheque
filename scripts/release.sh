#!/bin/bash
# Builds a universal Appothèque, signs it with Developer ID and the hardened runtime, notarizes and staples it,
# then writes dist/Appotheque-<version>.zip for the GitHub release and the Homebrew cask.
#
# Signing: the "Developer ID Application" identity in the login keychain, or APPLE_SIGNING_IDENTITY.
# Notarization, in this order:
#   NOTARY_PROFILE                 a profile created with `xcrun notarytool store-credentials`
#   APPLE_API_KEY, APPLE_API_ISSUER App Store Connect API key ID and issuer ID (environment)
#   Keychain items named by NOTARY_KEY_SERVICE and NOTARY_ISSUER_SERVICE holding the same two IDs
# The API key itself is read from ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8. Nothing is stored in the repository.
# --skip-notarize signs only, to test the hardened-runtime build locally.
set -euo pipefail
cd "$(dirname "$0")/.."

skip_notarize=false
[[ "${1:-}" == "--skip-notarize" ]] && skip_notarize=true

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
app="dist/Appothèque.app"
zip="dist/Appotheque-$version.zip"

identity="${APPLE_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[[ -n "$identity" ]] || { echo "No Developer ID Application identity found." >&2; exit 1; }

bash build.sh --arch arm64 --arch x86_64 >/dev/null
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"
echo "Signed $(lipo -archs "$app/Contents/MacOS/Appotheque") build of $version with $identity"

if $skip_notarize; then exit 0; fi

notary_args=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
else
  key_id="${APPLE_API_KEY:-$(security find-generic-password -s "${NOTARY_KEY_SERVICE:-daymon-notary-api-key}" -w 2>/dev/null || true)}"
  issuer="${APPLE_API_ISSUER:-$(security find-generic-password -s "${NOTARY_ISSUER_SERVICE:-daymon-notary-api-issuer}" -w 2>/dev/null || true)}"
  key_file="$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8"
  [[ -n "$key_id" && -n "$issuer" && -f "$key_file" ]] || { echo "No notarization credentials found (see the header of this script)." >&2; exit 1; }
  notary_args=(--key "$key_file" --key-id "$key_id" --issuer "$issuer")
fi

# Submit a zip, staple the ticket to the app, then zip the stapled app for distribution.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" "${notary_args[@]}" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
shasum -a 256 "$zip"
