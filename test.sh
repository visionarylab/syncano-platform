#!/bin/bash
set -e

usage() {
    echo "* Usage: $0 [app_or_apps_to_test][--fast][--with-migrations][--skip-linter][--skip-coverage]" >&2
    exit 1
}

LINTER=true
COVERAGE=true
SETUP=true
POSITIONAL=()

# Parse arguments.
for PARAM in "$@"; do
    case $PARAM in
    --fast)
        LINTER=false
        COVERAGE=false
        SETUP=false
        ;;
    --with-migrations)
        export TEST_MIGRATIONS=true
        ;;
    --skip-linter)
        LINTER=false
        ;;
    --skip-coverage)
        COVERAGE=false
        ;;
    --skip-setup)
        SETUP=false
        ;;
    --help)
        usage
        ;;
    *)
        POSITIONAL+=("$PARAM")
        ;;
    esac
done

set -- "${POSITIONAL[@]}" # restore positional parameters

if $SETUP; then
    echo "=== setup docker ==="
    PYTHONPATH="$PWD:$PYTHONPATH" python tools/setup_codebox.py
fi

if $LINTER; then
    make lint
fi

CMD="manage.py test --noinput --parallel ${PARALLEL_COUNT:-2} $*"
if [ "${LEGACY_CODEBOX_ENABLED:-false}" != "true" ]; then
    CMD="${CMD} --exclude-tag legacy_codebox"
fi

if [ "$#" == 0 ]; then
    CMDS=("${CMD} -e response_templates" "${CMD} response_templates")
else
    CMDS=("${CMD}")
fi

# Run tests
export DJANGO_SETTINGS_MODULE=settings.tests
if $COVERAGE; then
    coverage erase
    for cmd in "${CMDS[@]}"; do
        # shellcheck disable=SC2086
        coverage run $cmd
    done
    coverage combine
else
    for cmd in "${CMDS[@]}"; do
        # shellcheck disable=SC2086
        python $cmd
    done
fi

if $COVERAGE; then
    echo
    echo "=== coverage report ==="
    coverage report
fi
