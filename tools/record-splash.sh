#!/usr/bin/env bash
# Android 真机启动序列验收脚本（需本机安装 adb，设备开启 USB 调试）。
#
#   bash tools/record-splash.sh
#
# 依次录制三个场景到 splash-records/：
#   1) 冷启动未登录：先退出登录，再强制停止并启动
#   2) 冷启动已登录：保持登录态，强制停止并启动
#   3) 从后台恢复：启动后按 HOME，再切回
#
# 每段录屏用手动指定的时长；录完在本机逐帧核对：
#   - 是否出现白屏 / 黑屏
#   - 是否出现两次 Logo（原生一次 + Flutter 一次）
#   - 终端窗口是否按 图标→字标→终端→内容→光标→收起 顺序出现
#   - splash 与登录页 / 首页之间是否有 Logo 重叠或闪烁
set -euo pipefail
PKG="ai.zcode.zcode_mobile"
OUT="splash-records"
mkdir -p "$OUT"

adb devices | grep -qE '\tdevice$' || { echo "未检测到设备" >&2; exit 1; }

record() {
  local name="$1" seconds="$2"
  echo ">>> 录制 $name（${seconds}s），录屏开始后立即执行对应操作"
  adb shell screenrecord --time-limit "$seconds" "/sdcard/$name.mp4" &
  local pid=$!
  sleep 0.5
  "$3"
  wait "$pid" || true
  adb pull "/sdcard/$name.mp4" "$OUT/$name.mp4" >/dev/null
  adb shell rm "/sdcard/$name.mp4"
}

cold() {
  adb shell am force-stop "$PKG"
  sleep 1
  adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
}

resume() {
  adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 4
  adb shell input keyevent KEYCODE_HOME
  sleep 2
  adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
}

echo "请先在 App 内退出登录，然后按回车开始场景 1；保持登录态后按回车开始场景 2。"
read -r
record cold-signed-out 8 cold
read -r
record cold-signed-in 8 cold
read -r
record resume-from-background 12 resume

echo "录屏已保存到 $OUT/，请逐帧核对 README 中列出的四项。"
