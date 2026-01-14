#!/usr/bin/env bash
set -euo pipefail

PATCH_DIR="${PATCH_DIR:-debian/patches}"
SERIES_FILE="${SERIES_FILE:-$PATCH_DIR/series}"

usage() {
    cat <<'EOF'
Usage:
  patch-series-helper.sh create \
    --patch <name.patch> \
    --target <PVE/path.pm> \
    --orig <file.orig> \
    --mod <file.mod> \
    [--update-series]

  patch-series-helper.sh batch-create --list <file> [--update-series]

  patch-series-helper.sh add-series <name.patch>

  patch-series-helper.sh sort-series [--global]

Environment:
  PATCH_DIR    Path to patch directory (default: debian/patches)
  SERIES_FILE  Path to series file (default: debian/patches/series)
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

ensure_file() {
    local file="$1"
    [ -f "$file" ] || die "missing file: $file"
}

sort_and_emit() {
    local -n list_ref="$1"
    [ "${#list_ref[@]}" -eq 0 ] && return 0
    printf "%s\n" "${list_ref[@]}" | LC_ALL=C sort
}

series_is_sorted() {
    local prev=""
    local line=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        if [ -n "$prev" ] && [[ "$prev" > "$line" ]]; then
            return 1
        fi
        prev="$line"
    done < "$SERIES_FILE"
    return 0
}

add_to_series() {
    local patch="$1"
    local has_comments=0

    mkdir -p "$PATCH_DIR"
    touch "$SERIES_FILE"

    if grep -Fxq "$patch" "$SERIES_FILE"; then
        echo "Series already содержит: $patch"
        return 0
    fi

    if grep -q '^[[:space:]]*#' "$SERIES_FILE"; then
        has_comments=1
    fi

    if [ "$has_comments" -eq 1 ]; then
        echo "$patch" >> "$SERIES_FILE"
        echo "Добавлен в конец series (есть комментарии, порядок проверь вручную)."
        return 0
    fi

    if ! series_is_sorted; then
        echo "$patch" >> "$SERIES_FILE"
        echo "Series не отсортирован, добавлен в конец. Проверь порядок вручную."
        return 0
    fi

    local inserted=0
    local line=""
    local tmp
    tmp="$(mktemp)"

    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$inserted" -eq 0 ] && [[ "$patch" < "$line" ]]; then
            echo "$patch" >> "$tmp"
            inserted=1
        fi
        echo "$line" >> "$tmp"
    done < "$SERIES_FILE"

    if [ "$inserted" -eq 0 ]; then
        echo "$patch" >> "$tmp"
    fi

    mv "$tmp" "$SERIES_FILE"
    echo "Series обновлен: $patch"
}

sort_series() {
    local global=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --global)
                global=1
                shift
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    ensure_file "$SERIES_FILE"

    local tmp
    tmp="$(mktemp)"

    if [ "$global" -eq 1 ]; then
        local comments=()
        local entries=()
        local line=""
        local trimmed=""

        while IFS= read -r line || [ -n "$line" ]; do
            trimmed="${line%%#*}"
            trimmed="$(echo "$trimmed" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            if [ -z "$trimmed" ]; then
                if [[ "$line" =~ ^[[:space:]]*# ]]; then
                    comments+=("$line")
                fi
                continue
            fi
            entries+=("$trimmed")
        done < "$SERIES_FILE"

        if [ "${#comments[@]}" -gt 0 ]; then
            printf "%s\n" "${comments[@]}" >> "$tmp"
        fi
        sort_and_emit entries >> "$tmp"
    else
        local segment=()
        local line=""
        local trimmed=""

        while IFS= read -r line || [ -n "$line" ]; do
            trimmed="${line%%#*}"
            trimmed="$(echo "$trimmed" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            if [ -z "$trimmed" ] || [[ "$line" =~ ^[[:space:]]*# ]]; then
                sort_and_emit segment >> "$tmp"
                segment=()
                echo "$line" >> "$tmp"
            else
                segment+=("$trimmed")
            fi
        done < "$SERIES_FILE"

        sort_and_emit segment >> "$tmp"
    fi

    mv "$tmp" "$SERIES_FILE"
    echo "Series отсортирован."
}

create_patch() {
    local patch=""
    local target=""
    local orig=""
    local mod=""
    local update_series=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --patch)
                patch="${2:-}"
                shift 2
                ;;
            --target)
                target="${2:-}"
                shift 2
                ;;
            --orig)
                orig="${2:-}"
                shift 2
                ;;
            --mod)
                mod="${2:-}"
                shift 2
                ;;
            --update-series)
                update_series=1
                shift
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    [ -n "$patch" ] || die "missing --patch"
    [ -n "$target" ] || die "missing --target"
    [ -n "$orig" ] || die "missing --orig"
    [ -n "$mod" ] || die "missing --mod"

    ensure_file "$orig"
    ensure_file "$mod"

    mkdir -p "$PATCH_DIR"
    local out="$PATCH_DIR/$patch"
    local diff_rc=0

    if ! diff -u --label "$target" --label "$target" "$orig" "$mod" > "$out"; then
        diff_rc=$?
        if [ "$diff_rc" -gt 1 ]; then
            rm -f "$out"
            die "diff failed with exit code $diff_rc"
        fi
    fi

    if [ ! -s "$out" ]; then
        rm -f "$out"
        die "diff empty, patch not created"
    fi

    echo "Патч создан: $out"

    if [ "$update_series" -eq 1 ]; then
        add_to_series "$patch"
    fi
}

batch_create() {
    local list=""
    local update_series=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --list)
                list="${2:-}"
                shift 2
                ;;
            --update-series)
                update_series=1
                shift
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    [ -n "$list" ] || die "missing --list"
    ensure_file "$list"

    local line=""
    local trimmed=""
    local patch=""
    local target=""
    local orig=""
    local mod=""

    while IFS= read -r line || [ -n "$line" ]; do
        trimmed="${line%%#*}"
        trimmed="$(echo "$trimmed" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$trimmed" ] && continue

        set -- $trimmed
        [ $# -ge 4 ] || die "invalid entry: $line"
        patch="$1"
        target="$2"
        orig="$3"
        mod="$4"

        if [ "$update_series" -eq 1 ]; then
            create_patch --patch "$patch" --target "$target" --orig "$orig" --mod "$mod" --update-series
        else
            create_patch --patch "$patch" --target "$target" --orig "$orig" --mod "$mod"
        fi
    done < "$list"
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        create)
            shift
            create_patch "$@"
            ;;
        batch-create)
            shift
            batch_create "$@"
            ;;
        add-series)
            shift
            [ -n "${1:-}" ] || die "missing patch name for add-series"
            add_to_series "$1"
            ;;
        sort-series)
            shift
            sort_series "$@"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
