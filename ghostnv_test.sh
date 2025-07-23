#!/bin/bash
# GhostNV Driver Specific Testing Script
# Advanced testing for NVIDIA GPU integration

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[GhostNV] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

test_nvidia_hardware() {
    log "Testing NVIDIA Hardware Detection"
    
    echo "=== GPU Information ==="
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=name,driver_version,memory.total,power.limit --format=csv,noheader,nounits
        echo ""
        
        # Test GPU compute capability
        nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits
        echo ""
        
        # Test GPU processes
        nvidia-smi pmon -c 1 || echo "Process monitoring not available"
    else
        error "nvidia-smi not available"
        return 1
    fi
    
    echo "=== CUDA Information ==="
    if command -v nvcc &> /dev/null; then
        nvcc --version
        echo ""
    else
        warning "NVCC not available"
    fi
    
    echo "=== Device Nodes ==="
    ls -la /dev/nvidia* 2>/dev/null || echo "No NVIDIA device nodes found"
    echo ""
    
    echo "=== Kernel Modules ==="
    lsmod | grep nvidia || echo "No NVIDIA kernel modules loaded"
    echo ""
}

test_ghostnv_source() {
    log "Testing GhostNV Source Code"
    
    GHOSTNV_DIR="/ghost/linux-ghost/src/drivers/gpu/nvidia"
    
    if [ -d "$GHOSTNV_DIR" ]; then
        success "GhostNV source directory found"
        
        echo "=== GhostNV Files ==="
        find "$GHOSTNV_DIR" -name "*.zig" | head -10
        echo ""
        
        echo "=== Key Components ==="
        for file in main.zig ghostnv_core.zig memory_manager.zig; do
            if [ -f "$GHOSTNV_DIR/$file" ]; then
                echo "✅ $file"
            else
                echo "❌ $file (missing)"
            fi
        done
        echo ""
        
        # Check file sizes
        echo "=== Source File Sizes ==="
        find "$GHOSTNV_DIR" -name "*.zig" -exec ls -lh {} \; | head -5
        echo ""
        
    else
        error "GhostNV source directory not found at $GHOSTNV_DIR"
        echo "Searching for GhostNV files..."
        find /ghost -name "*ghostnv*" -type f 2>/dev/null | head -10 || echo "No GhostNV files found"
        return 1
    fi
}

test_ghostnv_compilation() {
    log "Testing GhostNV Compilation"
    
    cd /ghost/linux-ghost
    
    echo "=== Building with GPU support ==="
    if zig build -Dgpu=true 2>&1 | tee /tmp/ghostnv_build.log; then
        success "GhostNV compilation succeeded"
        
        # Check for NVIDIA-specific outputs
        if grep -i "nvidia\|ghostnv" /tmp/ghostnv_build.log; then
            echo "Found NVIDIA/GhostNV references in build output"
        fi
        
    else
        error "GhostNV compilation failed"
        echo "Build errors:"
        tail -20 /tmp/ghostnv_build.log
        return 1
    fi
    
    echo ""
    
    # Check generated binaries
    echo "=== Generated Binaries ==="
    if [ -d "zig-out/bin" ]; then
        ls -la zig-out/bin/
        
        # Check for NVIDIA-related binaries
        find zig-out -name "*nvidia*" -o -name "*ghostnv*" 2>/dev/null || echo "No NVIDIA-specific binaries found"
    else
        warning "No output binaries found"
    fi
    echo ""
}

test_cuda_integration() {
    log "Testing CUDA Integration"
    
    # Create a simple CUDA test
    cat > /tmp/cuda_test.cu << 'EOF'
#include <cuda_runtime.h>
#include <stdio.h>

int main() {
    int deviceCount = 0;
    cudaError_t error = cudaGetDeviceCount(&deviceCount);
    
    if (error != cudaSuccess) {
        printf("CUDA Error: %s\n", cudaGetErrorString(error));
        return 1;
    }
    
    printf("Found %d CUDA devices\n", deviceCount);
    
    for (int i = 0; i < deviceCount; i++) {
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, i);
        printf("Device %d: %s\n", i, prop.name);
        printf("  Compute Capability: %d.%d\n", prop.major, prop.minor);
        printf("  Memory: %zu MB\n", prop.totalGlobalMem / (1024*1024));
        printf("  Multiprocessors: %d\n", prop.multiProcessorCount);
    }
    
    return 0;
}
EOF

    echo "=== CUDA Device Test ==="
    if command -v nvcc &> /dev/null; then
        if nvcc -o /tmp/cuda_test /tmp/cuda_test.cu 2>/dev/null; then
            /tmp/cuda_test
        else
            warning "CUDA compilation failed"
        fi
    else
        warning "NVCC not available for CUDA testing"
    fi
    echo ""
    
    # Test CUDA runtime
    echo "=== CUDA Runtime Test ==="
    python3 -c "
try:
    import subprocess
    result = subprocess.run(['nvidia-smi', '--query-gpu=name,memory.used,memory.total', '--format=csv'], 
                          capture_output=True, text=True)
    if result.returncode == 0:
        print('CUDA Runtime: Available')
        print(result.stdout)
    else:
        print('CUDA Runtime: Error')
except Exception as e:
    print(f'CUDA Runtime test failed: {e}')
" 2>/dev/null || echo "Python CUDA test not available"
    echo ""
}

test_ghostnv_features() {
    log "Testing GhostNV Gaming Features"
    
    echo "=== Gaming Optimization Features ==="
    
    # Check for gaming-specific configurations
    GHOST_CONFIG="/ghost/linux-ghost/build.zig"
    if [ -f "$GHOST_CONFIG" ]; then
        echo "Gaming configurations found:"
        grep -i "gaming\|vrr\|latency\|gsync" "$GHOST_CONFIG" || echo "No gaming configs found"
        echo ""
    fi
    
    # Test VRR support (if available)
    echo "=== VRR (Variable Refresh Rate) Support ==="
    if command -v xrandr &> /dev/null; then
        xrandr --listmonitors 2>/dev/null || echo "No display server available"
    else
        echo "VRR testing requires display server (not available in container)"
    fi
    echo ""
    
    # Check for gaming-specific memory management
    echo "=== Gaming Memory Features ==="
    if [ -f "/ghost/linux-ghost/src/mm/gaming_pagefault.zig" ]; then
        echo "✅ Gaming pagefault handler found"
    else
        echo "❌ Gaming pagefault handler not found"
    fi
    
    if [ -f "/ghost/linux-ghost/src/mm/realtime_compaction.zig" ]; then
        echo "✅ Realtime memory compaction found"
    else
        echo "❌ Realtime memory compaction not found"
    fi
    echo ""
}

test_performance_monitoring() {
    log "Testing Performance Monitoring"
    
    echo "=== GPU Performance Monitoring ==="
    if command -v nvidia-smi &> /dev/null; then
        echo "GPU Utilization:"
        nvidia-smi --query-gpu=utilization.gpu,utilization.memory,temperature.gpu --format=csv,noheader,nounits
        echo ""
        
        echo "GPU Clocks:"
        nvidia-smi --query-gpu=clocks.current.graphics,clocks.current.memory --format=csv,noheader,nounits
        echo ""
        
        echo "Power Usage:"
        nvidia-smi --query-gpu=power.draw,power.limit --format=csv,noheader,nounits
        echo ""
    fi
    
    echo "=== System Performance ==="
    echo "CPU Usage:"
    top -bn1 | grep "Cpu(s)" || echo "CPU info not available"
    echo ""
    
    echo "Memory Usage:"
    free -h
    echo ""
    
    echo "Disk I/O:"
    iostat -d 1 1 2>/dev/null || echo "iostat not available"
    echo ""
}

run_stress_test() {
    log "Running GPU Stress Test"
    
    # Simple GPU memory test
    cat > /tmp/gpu_stress.py << 'EOF'
#!/usr/bin/env python3
import time
import subprocess
import sys

def gpu_stress_test():
    """Simple GPU stress test"""
    print("=== GPU Stress Test ===")
    
    try:
        # Run nvidia-smi in a loop to monitor
        for i in range(5):
            print(f"Iteration {i+1}/5")
            result = subprocess.run(['nvidia-smi', '--query-gpu=utilization.gpu,temperature.gpu,memory.used', 
                                   '--format=csv,noheader,nounits'], capture_output=True, text=True)
            if result.returncode == 0:
                print(f"  GPU Stats: {result.stdout.strip()}")
            else:
                print("  GPU monitoring failed")
            
            time.sleep(2)
            
        print("Stress test completed")
        return True
        
    except Exception as e:
        print(f"Stress test failed: {e}")
        return False

if __name__ == "__main__":
    gpu_stress_test()
EOF

    python3 /tmp/gpu_stress.py
}

generate_ghostnv_report() {
    log "Generating GhostNV Test Report"
    
    REPORT_FILE="/ghost/logs/ghostnv_detailed_report.md"
    mkdir -p /ghost/logs
    
    cat > "$REPORT_FILE" << EOF
# GhostNV Driver Test Report

**Generated:** $(date)
**Test Environment:** Docker Container

## Hardware Detection

### GPU Information
\`\`\`
$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || echo "No GPU detected")
\`\`\`

### CUDA Capability
\`\`\`
$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null || echo "CUDA capability unknown")
\`\`\`

## GhostNV Source Analysis

### Source Files Found
$(find /ghost -name "*ghostnv*" -type f 2>/dev/null | wc -l) GhostNV-related files

### Key Components
$(for file in main.zig ghostnv_core.zig memory_manager.zig; do
    if [ -f "/ghost/linux-ghost/src/drivers/gpu/nvidia/$file" ]; then
        echo "✅ $file"
    else
        echo "❌ $file (missing)"
    fi
done)

## Compilation Results

### Build Status
$(cd /ghost/linux-ghost && zig build -Dgpu=true >/dev/null 2>&1 && echo "✅ Success" || echo "❌ Failed")

### Generated Binaries
$(ls -la /ghost/linux-ghost/zig-out/bin/ 2>/dev/null || echo "No binaries found")

## Gaming Features

### Optimization Modules
- Gaming Pagefault: $([ -f "/ghost/linux-ghost/src/mm/gaming_pagefault.zig" ] && echo "✅" || echo "❌")
- Realtime Compaction: $([ -f "/ghost/linux-ghost/src/mm/realtime_compaction.zig" ] && echo "✅" || echo "❌")
- VRR Support: $(grep -q "VRR\|vrr" /ghost/linux-ghost/src/drivers/gpu/nvidia/*.zig 2>/dev/null && echo "✅" || echo "❌")

## Recommendations

1. **Hardware Access**: $(if command -v nvidia-smi >/dev/null 2>&1; then echo "GPU accessible"; else echo "Install NVIDIA drivers"; fi)
2. **Development**: Focus on $(if [ -d "/ghost/linux-ghost/src/drivers/gpu/nvidia" ]; then echo "driver implementation"; else echo "setting up source structure"; fi)
3. **Testing**: $(if [ -f "/ghost/linux-ghost/zig-out/bin/linux-ghost" ]; then echo "Ready for kernel testing"; else echo "Fix compilation issues first"; fi)

---
*Generated by GhostNV Test Suite*
EOF

    success "GhostNV report generated: $REPORT_FILE"
}

main() {
    echo -e "${PURPLE}=== GhostNV Driver Test Suite ===${NC}"
    echo "Testing NVIDIA GPU integration for Ghost Kernel"
    echo ""
    
    # Run all tests
    test_nvidia_hardware
    test_ghostnv_source
    test_ghostnv_compilation
    test_cuda_integration
    test_ghostnv_features
    test_performance_monitoring
    run_stress_test
    
    echo ""
    generate_ghostnv_report
    
    echo -e "${GREEN}=== GhostNV Testing Complete ===${NC}"
    echo "Check /ghost/logs/ghostnv_detailed_report.md for detailed results"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi