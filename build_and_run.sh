#!/bin/sh

compile_shaders=false

for arg in "$@"; do
    case "$arg" in
        --compile-shaders)
            compile_shaders=true
            ;;
    esac
done

if [ "$compile_shaders" = "true" ]; then
    cd ./shaders || exit 1
    ./compile.sh || exit 1
    cd .. || exit 1
fi

odin build ./src -debug -out:TransactionsViewer || exit 1

./TransactionsViewer
