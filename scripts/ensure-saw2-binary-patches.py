#!/usr/bin/env python3
# Adds generic pre-codegen binary byte patches to the pinned local ReXGlue SDK.
# Syntax:
#   REXGLUE_BINARY_PATCHES="ADDRESS:HEXBYTES,ADDRESS:HEXBYTES,..."

from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: ensure-saw2-binary-patches.py /path/to/rexglue-sdk")

sdk = Path(sys.argv[1]).resolve()
header = sdk / "include/rex/codegen/binary_view.h"
source = sdk / "src/codegen/binary_view.cpp"
project = sdk / "src/codegen/project_recompiler.cpp"

for path in (header, source, project):
    if not path.is_file():
        raise SystemExit(f"[saw2-patches] missing ReXGlue source: {path}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"[saw2-patches] anchor not found: {label}")
    return text.replace(old, new, 1)

# BinaryView public patch API.
text = header.read_text(encoding="utf-8")
if "bool patch(uint32_t address" not in text:
    text = replace_once(
        text,
        "  const uint8_t* translate(uint32_t addr) const;\n"
        "  bool isExecutable(uint32_t addr) const;\n",
        "  const uint8_t* translate(uint32_t addr) const;\n"
        "  bool patch(uint32_t address, std::span<const uint8_t> bytes);\n"
        "  bool isExecutable(uint32_t addr) const;\n",
        "BinaryView::patch declaration",
    )
    header.write_text(text, encoding="utf-8")

# BinaryView mutation implementation.
text = source.read_text(encoding="utf-8")
if "bool BinaryView::patch(uint32_t address" not in text:
    if "#include <algorithm>\n" not in text:
        text = replace_once(
            text,
            "#include <limits>\n",
            "#include <algorithm>\n#include <limits>\n",
            "binary_view.cpp includes",
        )

    translate_block = '''const uint8_t* BinaryView::translate(uint32_t addr) const {
  for (const auto& section : sections_) {
    if (auto* ptr = section.translate(addr)) {
      return ptr;
    }
  }
  return nullptr;
}

'''
    patch_impl = translate_block + '''bool BinaryView::patch(uint32_t address, std::span<const uint8_t> bytes) {
  if (bytes.empty()) {
    return true;
  }

  for (size_t i = 0; i < sections_.size(); ++i) {
    auto& section = sections_[i];
    if (address < section.baseAddress) {
      continue;
    }

    const uint64_t offset = uint64_t(address) - section.baseAddress;
    if (offset > section.size || bytes.size() > uint64_t(section.size) - offset) {
      continue;
    }

    auto& data = sectionData_[i];
    std::copy(bytes.begin(), bytes.end(),
              data.begin() + static_cast<size_t>(offset));
    section.data = data.data();
    return true;
  }

  return false;
}

'''
    text = replace_once(
        text, translate_block, patch_impl, "BinaryView::translate implementation"
    )
    source.write_text(text, encoding="utf-8")

# Project recompiler: parse env, patch BinaryView before analysis, fingerprint it.
text = project.read_text(encoding="utf-8")
if "ApplyEnvironmentBinaryPatches" not in text:

    if "#include <cstdlib>\n" not in text:
        text = replace_once(
            text,
            "#include <algorithm>\n#include <filesystem>\n",
            "#include <algorithm>\n#include <cstdlib>\n#include <filesystem>\n",
            "project_recompiler includes",
        )

    fingerprint_old = '''  };

  return ComputeInputFingerprint(inputs, sdkVersion, flags);
}

'''
    fingerprint_new = '''  };

  if (const char* binary_patches = std::getenv("REXGLUE_BINARY_PATCHES")) {
    flags.push_back(fmt::format("binary_patches={}", binary_patches));
  }

  return ComputeInputFingerprint(inputs, sdkVersion, flags);
}

'''
    text = replace_once(
        text, fingerprint_old, fingerprint_new, "binary patch fingerprint"
    )

    report_anchor = '''void ReportBinaryInfo(ProgressReporter* reporter, std::string_view display_name,
                      const rex::runtime::XexModule& xex) {
'''
    parser = r'''bool ApplyEnvironmentBinaryPatches(BinaryView& view) {
  const char* raw = std::getenv("REXGLUE_BINARY_PATCHES");
  if (!raw || !*raw) {
    return true;
  }

  auto hex_nibble = [](char c) -> int {
    if (c >= '0' && c <= '9')
      return c - '0';
    if (c >= 'a' && c <= 'f')
      return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
      return c - 'A' + 10;
    return -1;
  };

  std::string spec(raw);
  size_t cursor = 0;
  while (cursor < spec.size()) {
    size_t comma = spec.find(',', cursor);
    if (comma == std::string::npos)
      comma = spec.size();

    std::string token = spec.substr(cursor, comma - cursor);
    size_t colon = token.find(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= token.size()) {
      REXLOG_ERROR("Invalid REXGLUE_BINARY_PATCHES token '{}'", token);
      return false;
    }

    std::string address_text = token.substr(0, colon);
    std::string hex_bytes = token.substr(colon + 1);
    if ((hex_bytes.size() & 1u) != 0) {
      REXLOG_ERROR("Binary patch at {} has an odd number of hex digits", address_text);
      return false;
    }

    char* address_end = nullptr;
    unsigned long parsed_address =
        std::strtoul(address_text.c_str(), &address_end, 16);
    if (!address_end || *address_end != '\0' || parsed_address > 0xFFFFFFFFul) {
      REXLOG_ERROR("Invalid binary patch address '{}'", address_text);
      return false;
    }

    std::vector<uint8_t> bytes;
    bytes.reserve(hex_bytes.size() / 2);
    for (size_t i = 0; i < hex_bytes.size(); i += 2) {
      int hi = hex_nibble(hex_bytes[i]);
      int lo = hex_nibble(hex_bytes[i + 1]);
      if (hi < 0 || lo < 0) {
        REXLOG_ERROR("Invalid hex byte in binary patch '{}'", token);
        return false;
      }
      bytes.push_back(static_cast<uint8_t>((hi << 4) | lo));
    }

    uint32_t address = static_cast<uint32_t>(parsed_address);
    if (!view.patch(address, bytes)) {
      REXLOG_ERROR(
          "Binary patch 0x{:08X} ({} byte{}) is outside loaded sections",
          address, bytes.size(), bytes.size() == 1 ? "" : "s");
      return false;
    }

    REXCODEGEN_TRACE("Applied binary patch at 0x{:08X} ({} byte{})",
                     address, bytes.size(), bytes.size() == 1 ? "" : "s");
    cursor = comma + 1;
  }

  return true;
}

'''
    text = replace_once(
        text, report_anchor, parser + report_anchor, "binary patch parser"
    )

    bv_old = '''    auto execMod = runtime->kernel_state()->GetExecutableModule();
    auto bv = BinaryView::fromModule(*execMod->xex_module());

    auto entry_display = make_display_name(targeted[0].config.filePath);
'''
    bv_new = '''    auto execMod = runtime->kernel_state()->GetExecutableModule();
    auto bv = BinaryView::fromModule(*execMod->xex_module());
    if (!ApplyEnvironmentBinaryPatches(bv)) {
      return Err<void>(ErrorCategory::Config,
                       "Failed to apply REXGLUE_BINARY_PATCHES to entrypoint");
    }

    auto entry_display = make_display_name(targeted[0].config.filePath);
'''
    text = replace_once(
        text, bv_old, bv_new, "entrypoint BinaryView patch hook"
    )
    project.write_text(text, encoding="utf-8")

# Sanity.
for path, needles in {
    header: ["bool patch(uint32_t address"],
    source: ["bool BinaryView::patch(uint32_t address"],
    project: [
        "ApplyEnvironmentBinaryPatches",
        'std::getenv("REXGLUE_BINARY_PATCHES")',
        "Failed to apply REXGLUE_BINARY_PATCHES",
        'fmt::format("binary_patches={}"',
    ],
}.items():
    current = path.read_text(encoding="utf-8")
    missing = [needle for needle in needles if needle not in current]
    if missing:
        raise SystemExit(f"[saw2-patches] sanity check failed for {path}: {missing}")

print("[saw2-patches] ReXGlue codegen binary patch support: OK (no root patch generated)")
