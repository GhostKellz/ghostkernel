# 👻 Ghost Kernel – High-Performance Kernel for Arch and Beyond

**Linux-Ghost** is a bleeding-edge, performance-focused Linux kernel designed for modern workstations, gaming rigs, and homelab environments. Built from mainline `linux-6.15.x`, it combines the best of Bore and EEVDF schedulers, GPU acceleration, and cutting-edge I/O enhancements — all while targeting Arch-based systems.

---

## 👻 What is Linux-Ghost?

Linux-Ghost is a modular kernel framework that:

* Uses **mainline Linux 6.15+** as its base
* Enables **Bore-EEVDF** as the default scheduler (no BMQ, CFS, or PDS clutter)
* Optimized for **NVIDIA Open Kernel Module 570+** support (no DKMS)
* Fully compatible with **Arch Linux** and **Btrfs** systems
* Offers a `-cachy` edition with additional Cachy-style patches & tweaks
* Includes advanced tuning for **Elgato capture cards**, **AMD Ryzen 3D** and **general Ryzen performance enhancements**, **game mode enhancements**, and **low-latency input response**

---

## ⚙️ Core Scheduler Design

* ✅ **Default**: `BORE + EEVDF hybrid` — Best of both worlds: responsiveness + latency control
* 🛑 **Excluded**: CFS, BMQ, PDS — We focus on the modern direction Linux is headed
* 💡 Future-proof: Will track upstream Bore/EEVDF evolution per kernel release

---

## 🎮 GPU & NVIDIA Support

* 🎯 Integrated NVIDIA Open driver support (v570+)
* 🚫 No DKMS needed — integrated at build time
* ✅ Works like AMD: native, streamlined, no fallback issues
* 🧪 Future: custom **`ghostnv`** Open NVIDIA driver with pre-applied latency, compute, and gaming optimizations
* 🧰 Will support: `linux-ghost`, `linux`, and `linux-zen` as native kernel modules
* 🧵 Optional plans for monolithic builds with `ghostnv` baked directly into the kernel

---

## 🧪 Performance & Hardware Enhancements

* 🚀 ZSTD compression for kernel & initramfs
* 🧠 Elgato + HDMI capture card patches baked in
* 🔥 Real-time capable kernel options (CONFIG\_PREEMPT + tuned sysctl)
* 📦 Integrated patches from CachyOS, Zen, and TKG (where applicable)
* 🧰 All mitigations off by default, uclamp boost tuned, and SCHED\_CORE toggles
* 🔧 AMD Ryzen 3D-specific and general Ryzen performance patches baked in

---

## 🔧 Editions

### linux-ghost

* Base kernel with Bore-EEVDF
* Arch-optimized with fast boot, zstd compression, bcachefs, zram
* NVIDIA Open Kernel Module built-in support

### linux-ghost-cachy

* Adds extra Cachy-style scheduler enhancements (sched-ext, mitigations off, uclamp tweaks)
* Mirrors many performance boosts seen in CachyOS but tailored for our streamlined architecture

---

## 📦 Goals

* 🧠 Designed for `ghostctl`, `phantomboot`, `jarvisd`, and Arch systems
* ⚡ Target low latency, high throughput compute/gaming workloads
* 🎯 Clean fallback behavior — all bootable with stock kernels if needed
* 🧰 Optional Zig build toolchain planned for `ghostkernel.zig`

---

## 🛠 Planned Features

* [x] Bore + EEVDF default kernel
* [x] Elgato & Capture Card Optimizations
* [x] Real-Time patches for specific editions
* [ ] Custom NVIDIA Open integration (`ghostnv`)
* [ ] Zig-native kernel build pipeline
* [ ] GitHub Actions for Arch-based `ghostctl` install
* [ ] Support in `phantomboot` for recovery & rollback

---

## 🔮 Vision

Linux-Ghost is more than a kernel — it’s a foundation for:

* ⚙️ System-level performance automation via `ghostctl`
* 🧬 Native NVIDIA experience without headaches
* 🌩️ Real-time gaming, desktop, and AI inference workloads
* 💾 Live system recovery (via `phantomboot` + Btrfs snapshots)

Ghost your kernel. Accelerate your stack.

---

Built for Arch. Built for speed. Built for control.

**Linux-Ghost ⚡**

