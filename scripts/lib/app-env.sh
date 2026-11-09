# shellcheck shell=bash
# Sourced by scripts that read Config/app.env. Owns the parser and the derived app identity.

# app_env_load FILE KEY...: sets each named KEY from FILE. The key is the text before the
# first "=", the value everything after it; a later line wins. Unlisted keys are ignored.
app_env_load() {
    local app_env_file="$1" app_env_line app_env_key app_env_wanted
    shift
    while IFS= read -r app_env_line; do
        app_env_key="${app_env_line%%=*}"
        for app_env_wanted in "$@"; do
            if [[ "$app_env_key" == "$app_env_wanted" ]]; then
                printf -v "$app_env_key" '%s' "${app_env_line#*=}"
            fi
        done
    done < "$app_env_file"
}

# app_bundle_id BUNDLE_PREFIX APPNAME
app_bundle_id() {
    local lower
    lower="$(printf '%s' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9-]/-/g')"
    printf '%s.%s' "$1" "$lower"
}

# app_signing_cn APPNAME
app_signing_cn() { printf '%s Release Signing' "$1"; }

# app_signing_keychain APPNAME
app_signing_keychain() { printf '%s/Library/Keychains/%s-signing.keychain-db' "$HOME" "$1"; }

# app_env_value FILE KEY: prints the first KEY= value (the rule MSBuild uses), or nothing.
app_env_value() { sed -n "s/^$2=//p" "$1" | head -n 1; }

# The designated requirement in Config/signing-requirement.txt: written once, parsed on import.
# app_signing_requirement BUNDLE_ID SHA1
app_signing_requirement() { printf 'identifier "%s" and certificate leaf = H"%s"\n' "$1" "$2"; }

# app_signing_requirement_hash FILE: prints the certificate SHA-1 from a requirement file.
app_signing_requirement_hash() { sed -n 's/.*H"\([0-9a-f]\{40\}\)".*/\1/p' "$1"; }

# app_env_get FILE KEY: prints KEY's value by the app_env_load rule, or nothing; sets no variables.
app_env_get() ( unset "$2"; app_env_load "$1" "$2"; printf '%s' "${!2-}" )
