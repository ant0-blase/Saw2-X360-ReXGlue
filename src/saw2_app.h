// saw2 - ReXGlue Recompiled Project
//
// Saw II-specific runtime hooks. Diagnostics use title-local environment
// variables and output files.

#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <thread>
#include <vector>

#include <rex/logging.h>
#include <rex/rex_app.h>
#include <rex/system/interfaces/graphics.h>
#include <rex/ui/presenter.h>

class Saw2App : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<Saw2App>(
        new Saw2App(ctx, "saw2", PPCImageConfig));
  }

 protected:
  void OnLoadXexImage(std::string& xex_image) override {
    // The retail disc uses this spelling. ReXApp's lowercase default is not a
    // valid path on a case-sensitive Linux filesystem.
    xex_image = "game:\\Default.xex";
  }

  void OnPostLaunchModule(rex::system::XThread* thread) override {
    (void)thread;
    capture_stop_.store(false, std::memory_order_release);
    capture_thread_ = std::thread([this]() { CaptureFirstVisibleGuestFrame(); });
  }

  void OnShutdown() override {
    capture_stop_.store(true, std::memory_order_release);
    if (capture_thread_.joinable()) {
      capture_thread_.join();
    }
  }

 private:
  void CaptureFirstVisibleGuestFrame() {
    bool saw_guest_output = false;
    for (unsigned attempt = 0;
         attempt < 1200 && !capture_stop_.load(std::memory_order_acquire);
         ++attempt) {
      auto* current_runtime = runtime();
      auto* graphics = current_runtime ? current_runtime->graphics_system() : nullptr;
      auto* presenter = graphics ? graphics->presenter() : nullptr;
      rex::ui::RawImage image;
      if (!presenter || !presenter->CaptureGuestOutput(image)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
        continue;
      }

      const size_t minimum_stride = size_t(image.width) * 4;
      const size_t required_size = image.height
                                       ? image.stride * size_t(image.height - 1) +
                                             minimum_stride
                                       : 0;
      if (!image.width || !image.height || image.stride < minimum_stride ||
          image.data.size() < required_size) {
        REXLOG_ERROR(
            "[GPU] Saw II guest output has invalid storage: {}x{}, stride={}, "
            "bytes={}",
            image.width, image.height, image.stride, image.data.size());
        return;
      }

      size_t non_black_pixels = 0;
      uint8_t minimum_channel = 255;
      uint8_t maximum_channel = 0;
      uint64_t checksum = 1469598103934665603ull;
      for (uint32_t y = 0; y < image.height; ++y) {
        const uint8_t* row = image.data.data() + image.stride * size_t(y);
        for (uint32_t x = 0; x < image.width; ++x) {
          const uint8_t* pixel = row + size_t(x) * 4;
          non_black_pixels += (pixel[0] | pixel[1] | pixel[2]) != 0;
          for (unsigned channel = 0; channel < 3; ++channel) {
            minimum_channel = std::min(minimum_channel, pixel[channel]);
            maximum_channel = std::max(maximum_channel, pixel[channel]);
            checksum = (checksum ^ pixel[channel]) * 1099511628211ull;
          }
        }
      }

      if (!saw_guest_output) {
        saw_guest_output = true;
        REXLOG_INFO(
            "[GPU] Saw II first guest output reached Presenter: {}x{}, "
            "stride={}",
            image.width, image.height, image.stride);
        REXLOG_INFO(
            "[GPU] Saw II first guest output pixels: non_black={}/{}, "
            "channel_range={}-{}, rgb_fnv1a={:016X}",
            non_black_pixels, size_t(image.width) * image.height,
            minimum_channel, maximum_channel, checksum);
      }
      if (!non_black_pixels || maximum_channel < 16 ||
          unsigned(maximum_channel - minimum_channel) < 8) {
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
        continue;
      }

      REXLOG_INFO(
          "[GPU] SAW2 FIRST VISIBLE FRAME: non_black={}/{}, "
          "channel_range={}-{}, rgb_fnv1a={:016X}",
          non_black_pixels, size_t(image.width) * image.height, minimum_channel,
          maximum_channel, checksum);

      const char* capture_path = std::getenv("SAW2_CAPTURE_FIRST_FRAME");
      if (capture_path && *capture_path) {
        const std::filesystem::path output_path(capture_path);
        std::error_code directory_error;
        if (!output_path.parent_path().empty()) {
          std::filesystem::create_directories(output_path.parent_path(),
                                              directory_error);
        }
        std::ofstream output(output_path, std::ios::binary | std::ios::trunc);
        if (!directory_error && output) {
          output << "P6\n" << image.width << ' ' << image.height << "\n255\n";
          std::vector<uint8_t> rgb(size_t(image.width) * image.height * 3);
          for (uint32_t y = 0; y < image.height; ++y) {
            const uint8_t* source =
                image.data.data() + image.stride * size_t(y);
            uint8_t* destination =
                rgb.data() + size_t(y) * image.width * 3;
            for (uint32_t x = 0; x < image.width; ++x) {
              destination[size_t(x) * 3 + 0] = source[size_t(x) * 4 + 0];
              destination[size_t(x) * 3 + 1] = source[size_t(x) * 4 + 1];
              destination[size_t(x) * 3 + 2] = source[size_t(x) * 4 + 2];
            }
          }
          output.write(reinterpret_cast<const char*>(rgb.data()),
                       static_cast<std::streamsize>(rgb.size()));
          if (output) {
            REXLOG_INFO("[GPU] captured Saw II guest frame to {}",
                        output_path.string());
          } else {
            REXLOG_ERROR("[GPU] failed while writing Saw II frame to {}",
                         output_path.string());
          }
        } else {
          REXLOG_ERROR("[GPU] could not create Saw II frame capture {}",
                       output_path.string());
        }
      }
      return;
    }

    if (!capture_stop_.load(std::memory_order_acquire)) {
      if (saw_guest_output) {
        REXLOG_WARN(
            "[GPU] Saw II guest output stayed black/flat for 30 seconds");
      } else {
        REXLOG_WARN(
            "[GPU] Saw II produced no capturable guest output in 30 seconds");
      }
    }
  }

  std::atomic<bool> capture_stop_{false};
  std::thread capture_thread_;
};
