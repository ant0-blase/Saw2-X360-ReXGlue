#!/usr/bin/env python3
from pathlib import Path
import sys

def die(msg: str) -> None:
    print(f"[vulkan-alpha-blend] ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)

if len(sys.argv) != 2:
    die("usage: ensure-rexglue-vulkan-alpha-blend-fix.py <rexglue-sdk-root>")

root = Path(sys.argv[1]).expanduser().resolve()
path = root / "src/graphics/vulkan/pipeline_cache.cpp"
if not path.is_file():
    die(f"missing {path}")

text = path.read_text(encoding="utf-8")

if "kBlendFactorAlphaMap[32]" in text:
    print("[vulkan-alpha-blend] alpha blend factor mapping already fixed")
    print("[vulkan-alpha-blend] OK (no root patch generated)")
    raise SystemExit(0)

anchor = '''    render_target_out.src_color_blend_factor =
        kBlendFactorMap[uint32_t(blend_control.color_srcblend)];'''

alpha_map = '''    // Alpha blend factors need color-family Xenos factors remapped to
    // their alpha equivalents. D3D12 already does this; using the color map
    // here can produce incorrect alpha / transparency on Vulkan.
    static const PipelineBlendFactor kBlendFactorAlphaMap[32] = {
        /*  0 */ PipelineBlendFactor::kZero,
        /*  1 */ PipelineBlendFactor::kOne,
        /*  2 */ PipelineBlendFactor::kZero,  // unknown -> zero
        /*  3 */ PipelineBlendFactor::kZero,  // unknown -> zero
        /*  4 */ PipelineBlendFactor::kSrcAlpha,
        /*  5 */ PipelineBlendFactor::kOneMinusSrcAlpha,
        /*  6 */ PipelineBlendFactor::kSrcAlpha,
        /*  7 */ PipelineBlendFactor::kOneMinusSrcAlpha,
        /*  8 */ PipelineBlendFactor::kDstAlpha,
        /*  9 */ PipelineBlendFactor::kOneMinusDstAlpha,
        /* 10 */ PipelineBlendFactor::kDstAlpha,
        /* 11 */ PipelineBlendFactor::kOneMinusDstAlpha,
        /* 12 */ PipelineBlendFactor::kConstantAlpha,
        /* 13 */ PipelineBlendFactor::kOneMinusConstantAlpha,
        /* 14 */ PipelineBlendFactor::kConstantAlpha,
        /* 15 */ PipelineBlendFactor::kOneMinusConstantAlpha,
        /* 16 */ PipelineBlendFactor::kSrcAlphaSaturate,
        // 17..31 default to kZero.
    };

'''

if anchor not in text:
    die("could not find Vulkan blend mapping anchor; SDK source layout changed")

text = text.replace(anchor, alpha_map + anchor, 1)

old_src = '''    render_target_out.src_alpha_blend_factor =
        kBlendFactorMap[uint32_t(blend_control.alpha_srcblend)];'''
new_src = '''    render_target_out.src_alpha_blend_factor =
        kBlendFactorAlphaMap[uint32_t(blend_control.alpha_srcblend)];'''

old_dst = '''    render_target_out.dst_alpha_blend_factor =
        kBlendFactorMap[uint32_t(blend_control.alpha_destblend)];'''
new_dst = '''    render_target_out.dst_alpha_blend_factor =
        kBlendFactorAlphaMap[uint32_t(blend_control.alpha_destblend)];'''

if old_src not in text or old_dst not in text:
    die("could not find Vulkan alpha blend assignments")

text = text.replace(old_src, new_src, 1)
text = text.replace(old_dst, new_dst, 1)

path.write_text(text, encoding="utf-8")

verify = path.read_text(encoding="utf-8")
required = (
    "kBlendFactorAlphaMap[32]",
    "kBlendFactorAlphaMap[uint32_t(blend_control.alpha_srcblend)]",
    "kBlendFactorAlphaMap[uint32_t(blend_control.alpha_destblend)]",
)
if not all(x in verify for x in required):
    die("post-write verification failed")

print(f"[vulkan-alpha-blend] fixed {path}")
print("[vulkan-alpha-blend] OK (no root patch generated)")
