#!/usr/bin/env ruby
# scripts/patch-frameit.rb
#
# Patches the installed fastlane gem's frameit library to support iPhone 17 Pro
# and iPhone 17 Pro Max framing, inspired by fastlane PR #29921.
#
# What this patch does:
#   device_types.rb — adds IPHONE_17_PRO and IPHONE_17_PRO_MAX constants using
#                     the existing Device.new format; the required Color::SILVER
#                     constant already exists in frameit 2.232.2.
#   editor.rb       — extends the rounded-corner mask condition from iPhone 14
#                     only to iPhone 14–17 (regex iphone-?1[4-7]).
#
# Frame PNGs (Apple iPhone 17 Pro Silver.png, etc.) must already be present at
# ~/.fastlane/frameit/latest/. Run `bundle exec fastlane frameit download_frames`
# on a fresh machine before running this script.
#
# Idempotent — safe to run multiple times.
# Version-guarded — aborts clearly if fastlane is upgraded.
#
# Usage:
#   bundle exec ruby scripts/patch-frameit.rb

SENTINEL                  = "# PATCH: birch iPhone 17 frameit support"
EXPECTED_FASTLANE_VERSION = "2.232.2"

# ── Locate gem files ──────────────────────────────────────────────────────────
begin
  gem_spec = Gem::Specification.find_by_name('fastlane')
rescue Gem::MissingSpecError
  abort "ERROR: fastlane gem not found. Run `bundle install` first."
end

installed         = gem_spec.version.to_s
gem_dir           = gem_spec.gem_dir
device_types_path = File.join(gem_dir, "frameit/lib/frameit/device_types.rb")
editor_path       = File.join(gem_dir, "frameit/lib/frameit/editor.rb")

[device_types_path, editor_path].each do |path|
  abort "ERROR: #{path} not found. Is this a full fastlane install?" unless File.exist?(path)
end

# ── Short-circuit: native support (fastlane >= 2.238.0) ──────────────────────
# PR #29921 was merged upstream, so frameit now ships IPHONE_17_PRO /
# IPHONE_17_PRO_MAX and an iphone-17 rounded-corner mask of its own. When the
# installed gem already has both, this patch is unnecessary.
if File.read(device_types_path).include?("IPHONE_17_PRO_MAX ||=") &&
   File.read(editor_path).match?(/iphone-?17/)
  puts "fastlane #{installed} already supports iPhone 17 Pro / Pro Max natively (PR #29921)."
  puts "Nothing to patch — this script is a no-op on fastlane >= 2.238.0."
  exit(0)
end

unless installed == EXPECTED_FASTLANE_VERSION
  abort "ERROR: Expected fastlane #{EXPECTED_FASTLANE_VERSION}, found #{installed}.\n" \
        "Review the patch for the new version and update EXPECTED_FASTLANE_VERSION."
end

# ── Patch device_types.rb ────────────────────────────────────────────────────
# Adds two Device constants immediately before the iPad section.
# Resolution:  iPhone 17 Pro     → 1206×2622 (same as iPhone 16 Pro)
#              iPhone 17 Pro Max → 1320×2868 (native simulator screenshot size)
# Default color: Silver — matches "Apple iPhone 17 Pro Silver.png" frame asset.
# Color::SILVER is already defined in frameit 2.232.2 (no new Color needed).
#
dt_content = File.read(device_types_path)

if dt_content.include?(SENTINEL)
  puts "device_types.rb: already patched — skipping."
else
  anchor = "  IPAD_10_2 ||="

  unless dt_content.include?(anchor)
    abort "ERROR: Could not find '#{anchor}' in device_types.rb. " \
          "The gem structure may have changed — review the patch manually."
  end

  new_devices = \
    "    #{SENTINEL}\n" \
    "    IPHONE_17_PRO     ||= Device.new(\"iphone-17-pro\",     \"Apple iPhone 17 Pro\",     13, [[1206, 2622], [2622, 1206]], 460, Color::SILVER, Platform::IOS)\n" \
    "    IPHONE_17_PRO_MAX ||= Device.new(\"iphone-17-pro-max\", \"Apple iPhone 17 Pro Max\", 13, [[1320, 2868], [2868, 1320]], 460, Color::SILVER, Platform::IOS)\n" \
    "\n"

  File.write(device_types_path, dt_content.sub(anchor, new_devices + anchor))
  puts "device_types.rb: patched — added IPHONE_17_PRO and IPHONE_17_PRO_MAX."
end

# ── Patch editor.rb ──────────────────────────────────────────────────────────
# Extends the rounded-corner mask from iPhone 14 only to iPhone 14–17.
# The regex iphone-?1[4-7] matches iphone-14, iphone14, iphone-17-pro, etc.
#
ed_content = File.read(editor_path)

if ed_content.include?(SENTINEL)
  puts "editor.rb: already patched — skipping."
else
  old_condition = 'if screenshot.device.id.to_s.include?("iphone-14") || screenshot.device.id.to_s.include?("iphone14")'

  unless ed_content.include?(old_condition)
    abort "ERROR: Could not find the expected rounded-corner condition in editor.rb.\n" \
          "The gem may have changed — review the patch manually."
  end

  new_condition = "#{SENTINEL}\n          if screenshot.device.id.to_s.match?(/iphone-?1[4-7]/)"

  File.write(editor_path, ed_content.sub(old_condition, new_condition))
  puts "editor.rb: patched — extended rounded-corner mask to iphone-14 through iphone-17."
end

puts "\nDone. Re-run to confirm idempotency (both files should print 'already patched')."
