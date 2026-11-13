#!/system/bin/sh
# s25-probe.sh: read-only facts of a Galaxy S25 (SM-S931B, pa1q, SM8750) that OneiOS needs and that cannot be
# looked up: CPU (Oryon) ids and capacities, kernel config (page size, VA bits, KGSL, udmabuf), the GPU,
# the panel and the touch screen, haptics, battery, light sensor, Bluetooth HAL kind, SELinux labels.
#
# Run it as root with One UI running (KernelSU): from adb,
#   adb push tools/probe/s25-probe.sh /data/local/tmp/ && adb shell su -c 'sh /data/local/tmp/s25-probe.sh'
# or from a root terminal on the phone. It writes nothing but its own output folder and a .tar.gz of it, changes no
# setting, takes no serial number, IMEI, account or name (only the property keys listed below), and prints the path
# of the archive at the end. Send that archive (or the folder's files) back: docs/s25.md, "What the probe answers".
#
# Optional: with the runtime's phone checks in /data/local/tmp/oneios/bin (the fork's stage) it also runs
# `gpuctl` for 20 s (the KGSL path: context, buffer import, submit), which shows whether drm2kgsl works on Adreno 830.
#
# Every step is time-limited; a step that fails writes its error to the file and the probe goes on.

OUT=/data/local/tmp/oneios-s25-probe
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
rm -rf "$OUT"
mkdir -p "$OUT" || { echo "s25-probe: cannot make $OUT"; exit 1; }
[ "$(id -u)" = 0 ] || echo "s25-probe: not root: many files will be unreadable (run it through su)" >&2

# run NAME COMMAND...: the output (and errors) of the command in $OUT/NAME.txt, 20 s at most when `timeout` exists.
TMO=""
command -v timeout >/dev/null 2>&1 && TMO="timeout 20"
run() {
  name=$1; shift
  { echo "# $*"; $TMO "$@" 2>&1; echo "# exit $?"; } > "$OUT/$name.txt" 2>&1
}
# cat the small files of a directory (one line each), for sysfs folders.
dump_dir() {
  d=$1; out=$2
  { echo "# $d"; for f in "$d"/*; do
      [ -f "$f" ] || continue
      printf '%s: ' "$(basename "$f")"
      head -c 300 "$f" 2>&1 | tr '\n' ' '
      echo
    done; } >> "$OUT/$out.txt" 2>&1
}

# ---- identity (selected properties only) ----
{
  for k in ro.product.model ro.product.device ro.product.name ro.product.board ro.board.platform ro.soc.model \
           ro.soc.manufacturer ro.hardware ro.build.version.release ro.build.version.sdk ro.build.version.sdk_full \
           ro.build.version.security_patch ro.build.version.oneui ro.build.version.sem_platform_int \
           ro.build.version.sem_platform_minor ro.build.PDA ro.build.AP ro.build.flavor ro.build.type ro.boot.verifiedbootstate \
           ro.boot.flash.locked ro.boot.warranty_bit ro.vendor.api_level ro.product.first_api_level \
           ro.product.cpu.abilist ro.zygote ro.kernel.version ro.config.knox ro.boot.hardware.revision \
           persist.sys.dalvik.vm.lib.2 ro.surface_flinger.max_frame_buffer_acquired_buffers ro.sf.lcd_density \
           ro.vendor.build.fingerprint ro.bootimage.build.fingerprint; do
    printf '%s=%s\n' "$k" "$(getprop "$k")"
  done
  echo "uname: $(uname -a)"
  echo "selinux: $(getenforce 2>&1)"
  echo "id: $(id)"
  echo "pagesize: $(getconf PAGESIZE 2>&1)"
} > "$OUT/identity.txt" 2>&1

# ---- kernel ----
run kernel_version cat /proc/version
if [ -r /proc/config.gz ]; then
  { zcat /proc/config.gz 2>/dev/null || gzip -dc /proc/config.gz 2>/dev/null; } | grep -E \
    '^(# )?CONFIG_(ARM64_(4K|16K|64K)_PAGES|ARM64_VA_BITS|ARM64_VA_BITS_[0-9]+|PGTABLE_LEVELS|ARM64_PTR_AUTH|ARM64_PTR_AUTH_KERNEL|ARM64_BTI|ARM64_MTE|ARM64_SVE|ARM64_SME|ARM64_AMU_EXTN|ARM64_PAN|ARM64_E0PD|KVM|VIRTUALIZATION|MSM_KGSL|QCOM_KGSL|QCOM_KGSL_[A-Z_]*|UDMABUF|DMABUF_HEAPS|DRM_MSM|SECCOMP|SECCOMP_FILTER|USER_NS|PID_NS|NET_NS|UTS_NS|IPC_NS|CGROUPS|MEMCG|ANDROID_BINDER_IPC|ANDROID_BINDERFS|SECURITY_SELINUX|SECURITY_SELINUX_DEVELOP|MODULES|MODULE_SIG|KPROBES|UPROBES|BPF_SYSCALL|PERSISTENT_RAM|HZ|HZ_[0-9]+|TRANSPARENT_HUGEPAGE|COMPAT|ARM64_ERRATUM_[0-9]+|QCOM_[A-Z_]*ORYON[A-Z_]*|ARM_SCMI_[A-Z_]*|ARM_[A-Z_]*CPUFREQ[A-Z_]*|QCOM_CPUFREQ[A-Z_]*)[= ]' \
    > "$OUT/kernel_config.txt" 2>&1
else
  echo "no /proc/config.gz" > "$OUT/kernel_config.txt"
fi
run kernel_modules_udmabuf sh -c 'for f in /sys/module/udmabuf/parameters/*; do echo "$f: $(cat $f)"; done'
run kernel_proc_cpuinfo cat /proc/cpuinfo
# The highest mapped address of this very process: a 39-bit VA space ends at 0x8000000000, a 48-bit one at 0x1000000000000.
run kernel_va sh -c 'tail -n 3 /proc/self/maps; echo "---"; grep -E "stack|vdso" /proc/self/maps'
run kernel_ptrauth sh -c 'grep -E "^Features" /proc/cpuinfo | head -1; ls /proc/sys/abi 2>&1'

# ---- CPU ----
{
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n=$(basename "$c")
    echo "## $n"
    for f in cpu_capacity topology/core_id topology/cluster_id topology/physical_package_id \
             regs/identification/midr_el1 regs/identification/revidr_el1 \
             cpufreq/cpuinfo_max_freq cpufreq/cpuinfo_min_freq cpufreq/related_cpus cpufreq/scaling_governor \
             cpufreq/scaling_available_frequencies cpufreq/scaling_available_governors; do
      printf '%s: %s\n' "$f" "$(head -c 600 "$c/$f" 2>&1 | tr '\n' ' ')"
    done
    for i in 0 1 2 3 4 5; do
      [ -d "$c/cache/index$i" ] || continue
      printf 'cache index%s: level %s type %s size %s line %s ways %s shared %s\n' "$i" \
        "$(cat "$c/cache/index$i/level" 2>&1)" "$(cat "$c/cache/index$i/type" 2>&1)" "$(cat "$c/cache/index$i/size" 2>&1)" \
        "$(cat "$c/cache/index$i/coherency_line_size" 2>&1)" "$(cat "$c/cache/index$i/ways_of_associativity" 2>&1)" \
        "$(cat "$c/cache/index$i/shared_cpu_list" 2>&1)"
    done
  done
  echo "## online: $(cat /sys/devices/system/cpu/online 2>&1)  present: $(cat /sys/devices/system/cpu/present 2>&1)"
} > "$OUT/cpu.txt" 2>&1

# ---- GPU: KGSL (Samsung's /dev/kgsl-3d0) ----
run gpu_nodes sh -c 'ls -lZ /dev/kgsl-3d0 /dev/kgsl /dev/udmabuf /dev/dma_heap /dev/dri 2>&1'
: > "$OUT/gpu_kgsl_sysfs.txt"
for d in /sys/class/kgsl/kgsl-3d0 /sys/class/kgsl/kgsl-3d0/devfreq /sys/class/kgsl/kgsl; do
  [ -d "$d" ] && dump_dir "$d" gpu_kgsl_sysfs
done
run gpu_drm sh -c 'for c in /sys/class/drm/card*; do echo "== $c"; ls "$c"; cat "$c/device/uevent" 2>/dev/null; done'
run gpu_dmesg sh -c 'dmesg 2>&1 | grep -i -E "kgsl|adreno|a8[0-9][0-9]|gmu|udmabuf" | head -80'
# The runtime's KGSL check, when the stage has it: context, buffer import, submit (the fork's Hardware checks run the same).
GPUCTL=/data/local/tmp/oneios/bin/gpuctl
if [ -x "$GPUCTL" ]; then
  { echo "# $GPUCTL"; timeout 60 "$GPUCTL" 2>&1; echo "# exit $?"; } > "$OUT/gpu_gpuctl.txt" 2>&1
else
  echo "no $GPUCTL (the OneiOS runtime is not staged): skipped" > "$OUT/gpu_gpuctl.txt"
fi

# ---- display, touch, buttons ----
run display_size sh -c 'wm size; wm density'
run display_modes sh -c 'dumpsys display 2>&1 | grep -E "DisplayDeviceInfo|supportedModes|mBaseDisplayInfo|renderFrameRate|mActiveModeId|defaultModeId" | cut -c1-1200 | head -12'
run display_drm sh -c 'for m in /sys/class/drm/card*-*/modes; do echo "== $m"; head -20 "$m"; done 2>&1'
: > "$OUT/display_backlight.txt"
for d in /sys/class/backlight/*; do [ -d "$d" ] && dump_dir "$d" display_backlight; done
run input_devices cat /proc/bus/input/devices
run input_axes sh -c 'getevent -p 2>&1 | head -200'

# ---- haptics ----
run haptics_input sh -c 'grep -i -B1 -A8 -E "vib|haptic|cs40|ff" /proc/bus/input/devices | head -60'
run haptics_sysfs sh -c 'ls -d /sys/class/*vib* /sys/class/timed_output /sys/class/leds/vibrator 2>&1; for f in $(find /sys/class -maxdepth 3 \( -name f0_measured -o -name motor_type -o -name vib_type \) 2>/dev/null | head -10); do echo "$f: $(cat $f 2>&1)"; done'
run haptics_vintf sh -c 'grep -l -i vibrator /vendor/etc/vintf/*.xml /vendor/etc/vintf/manifest/*.xml 2>/dev/null | head; getprop | grep -i -E "vibr|haptic" | head'

# ---- battery and light sensor ----
: > "$OUT/battery.txt"
for d in /sys/class/power_supply/*; do [ -d "$d" ] && dump_dir "$d" battery; done
run als_sysfs sh -c 'ls /sys/class/sensors 2>&1 | head -50; for f in /sys/class/sensors/*light*/*; do [ -f "$f" ] && echo "$f: $(head -c 120 $f 2>&1 | tr "\n" " ")"; done 2>&1 | head -40'
run als_sensorservice sh -c 'dumpsys sensorservice 2>&1 | grep -i -E "light|ambient" | head -10'

# ---- Bluetooth, audio, camera: which HAL kind ----
run bt_hal sh -c 'service list 2>&1 | grep -i bluetooth; echo "--- vintf"; grep -h -i -B2 -A8 "bluetooth" /vendor/etc/vintf/manifest.xml /vendor/etc/vintf/manifest/*.xml /vendor/etc/vintf/*.xml 2>/dev/null | head -80; echo "--- hw"; ls /vendor/lib64/hw 2>&1 | grep -i -E "bluetooth|bt"; echo "--- tty"; ls -l /dev/ttyHS* /dev/hci* 2>&1; echo "--- hwbinder services"; ls /dev/hwbinder /dev/vndbinder /dev/binder 2>&1'
run bt_lshal sh -c 'command -v lshal && lshal 2>&1 | grep -i bluetooth | head -20'
run audio_hal sh -c 'ls /vendor/lib64/hw 2>&1 | grep -i -E "audio|aaudio"; getprop | grep -i -E "audio.*hal|aaudio" | head'
run camera sh -c 'dumpsys media.camera 2>&1 | grep -E "Camera ID|Device version|Facing|Number of camera" | head -40'

# ---- SELinux and root view ----
run selinux_context sh -c 'id -Z 2>&1; cat /proc/self/attr/current 2>&1; getenforce; ls -Z /data/local/tmp 2>&1 | head -5'
run selinux_denials sh -c 'dmesg 2>&1 | grep -i "avc: *denied" | grep -i -E "kgsl|udmabuf|dma_heap|input|binder" | tail -20'
run mem sh -c 'head -5 /proc/meminfo; cat /proc/sys/vm/overcommit_memory /proc/sys/vm/max_map_count'
run thermal sh -c 'for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type 2>&1): $(cat $z/temp 2>&1)"; done | head -40'

# ---- pack ----
ARCHIVE=/data/local/tmp/oneios-s25-probe-$STAMP.tar.gz
tar -czf "$ARCHIVE" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null || ARCHIVE="(tar failed: send the files of $OUT)"
[ -d /sdcard/Download ] && cp "$ARCHIVE" /sdcard/Download/ 2>/dev/null && echo "copy: /sdcard/Download/$(basename "$ARCHIVE")"
echo "s25-probe: done: $ARCHIVE ($(ls "$OUT" | wc -l) files in $OUT)"
