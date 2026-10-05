#!/bin/sh
# Sprawdza surowe źródła wymagane przez kompilację Metal w runtime iOS.
set -eu

if [ "$#" -ne 1 ]; then
    printf 'Użycie: sh %s /ścieżka/do/BubblePhysicsBench.app\n' "$0" >&2
    exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir="$script_dir/../../../Sources/BubblePhysicsReferenceMetal/Shaders"
bundle_dir="$1/BubblePhysics_BubblePhysicsReferenceMetal.bundle"

for name in ReferenceNewtonPCGKernels ReferenceGeometryKernels ReferencePostSolveKernels; do
    resource="$bundle_dir/$name.metal-source"
    if [ ! -s "$resource" ]; then
        printf 'Brak surowego źródła Metal w aplikacji: %s\n' "$resource" >&2
        exit 1
    fi
    if ! cmp -s "$source_dir/$name.metal-source" "$resource"; then
        printf 'Źródło Metal w aplikacji różni się od repozytorium: %s\n' "$resource" >&2
        exit 1
    fi
    printf 'OK: %s\n' "$resource"
done
