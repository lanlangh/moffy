#!/usr/bin/env ruby
# frozen_string_literal: true

# configure_screentime.rb
# ---------------------------------------------------------------------------
# ios/Runner.xcodeproj に DeviceActivityMonitor 拡張ターゲット "MoffyMonitor" を追加し、
# Runner へ埋め込み、family-controls + App Group のエンタイトルメントを配線する。
#
# 'xcodeproj' gem は **純 Ruby**（ネイティブ拡張なし）なので Linux CI で実行可（Mac 不要）。
#   gem install xcodeproj && ruby ios/tools/configure_screentime.rb
#
# 冪等: 既に MoffyMonitor が存在すれば拡張作成はスキップ（再実行安全）。
# Swift/plist/entitlements の実体ファイルは別途リポジトリにコミット済み。本スクリプトは
# pbxproj への「配線」だけを行う。
#
# 重要(レビュー反映): ファイル参照はすべて main_group(real_path = SRCROOT = ios/) に
# SRCROOT 相対パスで作る。既存 Runner グループ(path=Runner)に 'Runner/...' 付きで足すと
# ios/Runner/Runner/... に解決して "Build input file cannot be found" になるため。
# 作成後に各 ref の real_path が実在することを検証し、Mac なしでも誤配線を検知する。
# ---------------------------------------------------------------------------

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Runner.xcodeproj', __dir__)
EXT_NAME   = 'MoffyMonitor'
EXT_BUNDLE = 'com.moffy.app.MoffyMonitor'
DEPLOY     = '16.0' # FamilyControls の requestAuthorization(for:) が iOS 16+
SWIFT      = '5.0'

project = Xcodeproj::Project.open(PROJECT_PATH)
runner = project.targets.find { |t| t.name == 'Runner' }
abort 'configure_screentime: Runner target not found' unless runner

new_refs = []

# main_group(real_path = ios/)に SRCROOT 相対で作る → 解決先が決定的に正しい。
def srcroot_ref(project, path, collector)
  existing = project.files.find { |f| f.path == path }
  ref = existing || project.main_group.new_reference(path)
  collector << ref
  ref
end

# --- deployment target を 16.0 に引き上げ（プロジェクト＋Runner の両レベル） -------------
project.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOY }
runner.build_configurations.each do |c|
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOY
  # Runner に family-controls + App Group のエンタイトルメントを配線（SRCROOT 相対で正しい）。
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

# --- Runner に新規 Swift ソース（ScreenTime*）とエンタイトルメント参照を登録 -------------
srcroot_ref(project, 'Runner/Runner.entitlements', new_refs)
handler_ref = srcroot_ref(project, 'Runner/ScreenTimeHandler.swift', new_refs)
shared_ref  = srcroot_ref(project, 'Runner/ScreenTimeShared.swift', new_refs)

runner_sources = runner.source_build_phase.files_references
[handler_ref, shared_ref].each do |r|
  runner.add_file_references([r]) unless runner_sources.include?(r)
end

# --- 拡張ターゲット（冪等: 既存ならスキップ） ----------------------------------------------
ext = project.targets.find { |t| t.name == EXT_NAME }
if ext
  puts "configure_screentime: #{EXT_NAME} already exists — skipping target creation."
else
  # :app_extension => product_type 'com.apple.product-type.app-extension'（.appex）
  ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOY, nil, :swift)
  # Flutter は Debug/Release/Profile の3構成。new_target は Debug/Release のみ作るので Profile を追加。
  unless ext.build_configurations.map(&:name).include?('Profile')
    ext.add_build_configuration('Profile', :release)
  end

  ext_swift = srcroot_ref(project, "#{EXT_NAME}/#{EXT_NAME}.swift", new_refs)
  srcroot_ref(project, "#{EXT_NAME}/Info.plist", new_refs)
  srcroot_ref(project, "#{EXT_NAME}/#{EXT_NAME}.entitlements", new_refs)

  # 拡張のソース = 自前の swift ＋ 共有ファイル（両ターゲットにコンパイル）。
  ext.add_file_references([ext_swift, shared_ref])

  # $(FLUTTER_BUILD_NAME)/$(FLUTTER_BUILD_NUMBER) を解決させ、拡張のバージョンを Runner と一致
  # させるため Generated.xcconfig をベース構成にする（App Store はアプリと拡張のバージョン一致を要求）。
  generated = project.files.find { |f| f.path == 'Flutter/Generated.xcconfig' }

  ext.build_configurations.each do |c|
    c.base_configuration_reference = generated if generated
    bs = c.build_settings
    bs['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BUNDLE
    bs['PRODUCT_NAME'] = '$(TARGET_NAME)'
    bs['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
    bs['GENERATE_INFOPLIST_FILE'] = 'NO' # 自前の Info.plist を使う
    bs['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/#{EXT_NAME}.entitlements"
    bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOY
    bs['SWIFT_VERSION'] = SWIFT
    bs['SKIP_INSTALL'] = 'YES'
    bs['CODE_SIGN_STYLE'] = 'Automatic'
    bs['TARGETED_DEVICE_FAMILY'] = '1,2'
    bs['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
    bs['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
    bs['LD_RUNPATH_SEARCH_PATHS'] = [
      '$(inherited)',
      '@executable_path/Frameworks',
      '@executable_path/../../Frameworks',
    ]
  end

  # Runner が拡張をビルドするよう依存を張る。
  runner.add_dependency(ext)

  # .appex を Runner の PlugIns に埋め込み（Code Sign On Copy）。
  embed = runner.copy_files_build_phases.find do |p|
    p.symbol_dst_subfolder_spec == :plug_ins || p.dst_subfolder_spec == '13'
  end
  unless embed
    embed = runner.new_copy_files_build_phase('Embed App Extensions')
    embed.symbol_dst_subfolder_spec = :plug_ins # dstSubfolderSpec '13'
  end
  unless embed.files_references.include?(ext.product_reference)
    bf = embed.add_file_reference(ext.product_reference)
    bf.settings = { 'ATTRIBUTES' => %w[RemoveHeadersOnCopy CodeSignOnCopy] }
  end

  puts "configure_screentime: created #{EXT_NAME} (#{EXT_BUNDLE}) and embedded into Runner."
end

# --- 保存前の自己検証（Mac なしでの誤配線検知） -------------------------------------------
# 1) 追加した全ファイル参照の解決先が実在するか。
new_refs.uniq.each do |ref|
  rp = ref.real_path.to_s
  abort "configure_screentime: file ref does not resolve to an existing file: #{rp}" \
    unless File.exist?(rp)
end

# 2) Runner に MoffyMonitor.appex を CodeSignOnCopy で埋め込む phase があるか。
embed_phase = runner.copy_files_build_phases.find do |p|
  (p.symbol_dst_subfolder_spec == :plug_ins || p.dst_subfolder_spec == '13') &&
    p.files_references.include?(ext.product_reference)
end
abort 'configure_screentime: Embed App Extensions phase missing the .appex' unless embed_phase
codesign = embed_phase.files.find { |bf| bf.file_ref == ext.product_reference }
attrs = codesign&.settings&.dig('ATTRIBUTES') || []
abort 'configure_screentime: appex is not marked CodeSignOnCopy' unless attrs.include?('CodeSignOnCopy')

# 3) Runner / 拡張のソースに必要な swift が入っているか。
unless runner.source_build_phase.files_references.include?(handler_ref)
  abort 'configure_screentime: ScreenTimeHandler.swift not in Runner sources'
end
unless ext.source_build_phase.files_references.include?(shared_ref)
  abort 'configure_screentime: ScreenTimeShared.swift not in MoffyMonitor sources'
end

project.save

# 保存後に再オープンして壊れていないことを確認。
verify = Xcodeproj::Project.open(PROJECT_PATH)
unless verify.targets.any? { |t| t.name == EXT_NAME }
  abort "configure_screentime: verification failed — #{EXT_NAME} not present after save."
end
puts "configure_screentime: OK. Targets = #{verify.targets.map(&:name).join(', ')} (deployment #{DEPLOY})."
