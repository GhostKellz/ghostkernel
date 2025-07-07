# Ghost Kernel Patches

This directory contains patches for the Ghost Kernel project, organized by category and kernel version.

## Directory Structure

```
patches/
├── sched/              # Scheduler patches
│   ├── 0001-bore-eevdf.patch      # Bore-EEVDF for linux-ghost
│   ├── 0001-bore-cachy.patch      # BORE for linux-ghost-cachy  
│   └── 0001-sched-ext.patch       # sched-ext support
├── performance/        # Performance optimizations
│   ├── 0101-bbr3.patch            # BBR3 TCP congestion control
│   ├── 0102-lto-clang.patch       # Clang LTO support
│   ├── 0103-cpu-znver4.patch      # AMD Zen 4 optimizations
│   └── 0104-timer-1000hz.patch    # 1000Hz timer frequency
├── gaming/            # Gaming-specific patches
│   ├── 0201-fsync.patch           # Fsync for Steam Proton
│   ├── 0202-nvidia-open.patch     # NVIDIA Open driver support
│   ├── 0203-wine-ntsync.patch     # Wine NTSYNC support
│   └── 0204-low-latency.patch     # Low latency optimizations
├── memory/            # Memory management
│   ├── 0301-hugepages.patch       # Transparent hugepages
│   ├── 0302-mglru.patch           # Multi-generational LRU
│   └── 0303-zswap.patch           # ZSWAP improvements
├── io/                # I/O optimizations
│   ├── 0401-io-uring.patch        # io_uring optimizations
│   └── 0402-nvme.patch            # NVMe performance patches
├── cachy/             # CachyOS-specific patches
│   ├── 0501-cachy-sauce.patch     # CachyOS performance sauce
│   └── 0502-cachy-config.patch    # CachyOS default config
└── series/            # Patch series files
    ├── ghost.series              # linux-ghost patch order
    ├── ghost-cachy.series         # linux-ghost-cachy patch order
    └── experimental.series        # Experimental patches
```

## Patch Categories

### Scheduler Patches (`sched/`)
- **Bore-EEVDF**: Enhanced EEVDF with burst-oriented response for gaming
- **BORE**: CachyOS-style BORE scheduler for maximum gaming performance
- **sched-ext**: Runtime scheduler switching support

### Performance Patches (`performance/`)
- **BBR3**: Latest TCP congestion control for low-latency networking
- **LTO**: Link-time optimization with Clang/LLVM
- **CPU Optimizations**: Architecture-specific tuning (znver4, etc.)
- **Timer Frequency**: 1000Hz for gaming responsiveness

### Gaming Patches (`gaming/`)
- **Fsync**: Steam Proton compatibility for Windows games
- **NVIDIA**: Open driver integration and optimizations
- **Wine Support**: NTSYNC and other Wine-specific improvements
- **Low Latency**: Various latency reduction patches

### Memory Patches (`memory/`)
- **Hugepages**: Transparent hugepage optimizations
- **MGLRU**: Multi-generational least-recently-used for better memory management
- **ZSWAP**: Compressed swap improvements

## Patch Application Order

### linux-ghost (Bore-EEVDF variant)
```
# Scheduler
sched/0001-bore-eevdf.patch
sched/0001-sched-ext.patch

# Performance  
performance/0101-bbr3.patch
performance/0102-lto-clang.patch
performance/0103-cpu-znver4.patch
performance/0104-timer-1000hz.patch

# Gaming
gaming/0201-fsync.patch
gaming/0202-nvidia-open.patch
gaming/0203-wine-ntsync.patch
gaming/0204-low-latency.patch

# Memory & I/O
memory/0301-hugepages.patch
memory/0302-mglru.patch
io/0401-io-uring.patch
```

### linux-ghost-cachy (BORE + CachyOS variant)
```
# Scheduler (BORE instead of Bore-EEVDF)
sched/0001-bore-cachy.patch
sched/0001-sched-ext.patch

# CachyOS sauce
cachy/0501-cachy-sauce.patch

# Performance (same as ghost)
performance/0101-bbr3.patch
performance/0102-lto-clang.patch
performance/0103-cpu-znver4.patch
performance/0104-timer-1000hz.patch

# Gaming (same as ghost)
gaming/0201-fsync.patch
gaming/0202-nvidia-open.patch
gaming/0203-wine-ntsync.patch
gaming/0204-low-latency.patch
```

## Patch Sources

- **CachyOS**: Patches from `linux-cachyos` repository
- **linux-tkg**: Gaming and performance patches
- **Clear Linux**: Intel performance optimizations
- **Arch Linux**: Stability and compatibility patches
- **Community**: Various gaming and performance improvements

## Adding New Patches

1. Place patch file in appropriate category directory
2. Use numbered naming convention (e.g., `0105-new-feature.patch`)
3. Update relevant `.series` file with patch path
4. Test with both kernel variants
5. Update documentation

## Testing

Before adding patches to the main series:
1. Test individual patch application
2. Verify successful kernel compilation
3. Test runtime functionality
4. Check for conflicts with existing patches
5. Validate performance impact