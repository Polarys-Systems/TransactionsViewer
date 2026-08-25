#!/usr/bin/env bash

set -e

SHADER_DIR="$(dirname "$0")"
OUT_DIR="${1:-$SHADER_DIR}"

SHADERS=(
    "fullscreen.vert"
    "glass_blur.frag"
    "glass_compose.frag"
    "prof_overlay.frag"
    "prof_overlay.vert"
    "text.frag"
    "text.vert"
    "ui_glass.frag"
    "ui_panel.frag"
    "ui_panel.vert"
    "ui_rect.frag"
    "ui_rect.vert"
    "ui_texture.frag"
    "wave_background.frag"
    "wave_background.vert"
    "graph_charts.vert"
    "graph_charts.frag"
)

echo "Compiling shaders..."

for shader in "${SHADERS[@]}"; do
    src="$SHADER_DIR/$shader"
    out="$OUT_DIR/$shader.spv"

    if [ ! -f "$src" ]; then
        echo "  [WARN] Not found: $src — skipping"
        continue
    fi

    glslc "$src" -o "$out"
    echo "  [OK]   $shader  ->  $shader.spv"
done

echo "Done."
