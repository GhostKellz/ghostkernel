#!/bin/bash
# Ghost Kernel Testing Runner Script
# Comprehensive testing suite for Ghost Kernel and GhostNV driver

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
GHOST_ROOT="/data/projects/ghostkernel"
CONTAINER_NAME="ghost-kernel-testing"
IMAGE_NAME="ghost-kernel:latest"
LOG_DIR="$GHOST_ROOT/logs"

# Create log directory
mkdir -p "$LOG_DIR"

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
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

check_requirements() {
    log "Checking system requirements..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed"
        exit 1
    fi
    
    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        error "Docker Compose is not installed"
        exit 1
    fi
    
    # Check NVIDIA Docker Runtime
    if ! docker info | grep -q nvidia; then
        warning "NVIDIA Docker runtime may not be configured"
        echo "To install NVIDIA Container Toolkit:"
        echo "  1. curl -s -L https://nvidia.github.io/nvidia-container-runtime/gpgkey | sudo apt-key add -"
        echo "  2. distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID)"
        echo "  3. curl -s -L https://nvidia.github.io/nvidia-container-runtime/\$distribution/nvidia-container-runtime.list | sudo tee /etc/apt/sources.list.d/nvidia-container-runtime.list"
        echo "  4. sudo apt-get update && sudo apt-get install -y nvidia-container-runtime"
        echo "  5. sudo systemctl restart docker"
    fi
    
    # Check NVIDIA GPU
    if command -v nvidia-smi &> /dev/null; then
        log "NVIDIA GPU detected:"
        nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits | head -3
    else
        warning "nvidia-smi not found - GPU testing may be limited"
    fi
}

build_container() {
    log "Building Ghost Kernel container..."
    
    cd "$GHOST_ROOT"
    
    # Build the container
    if docker-compose build --no-cache ghost-kernel-test; then
        success "Container built successfully"
    else
        error "Container build failed"
        exit 1
    fi
}

run_basic_tests() {
    log "Running basic Ghost Kernel tests..."
    
    cd "$GHOST_ROOT"
    
    # Run the test container
    docker-compose run --rm ghost-kernel-test /ghost/test_gpu.py 2>&1 | tee "$LOG_DIR/basic_tests.log"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        success "Basic tests completed"
    else
        warning "Some basic tests may have failed - check logs"
    fi
}

run_kernel_compilation_test() {
    log "Testing kernel compilation..."
    
    cd "$GHOST_ROOT"
    
    # Test compilation in container
    docker-compose run --rm ghost-kernel-test bash -c "
        cd /ghost/linux-ghost && 
        echo '=== Ghost Kernel Compilation Test ===' &&
        zig build --verbose 2>&1 &&
        echo '=== Checking output binaries ===' &&
        ls -la zig-out/bin/ || echo 'No binaries found' &&
        echo '=== Compilation test complete ==='
    " 2>&1 | tee "$LOG_DIR/kernel_compilation.log"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        success "Kernel compilation test passed"
    else
        error "Kernel compilation test failed"
    fi
}

run_ghostnv_tests() {
    log "Running GhostNV driver tests..."
    
    cd "$GHOST_ROOT"
    
    # Test GhostNV driver functionality
    docker-compose run --rm ghost-kernel-test bash -c "
        echo '=== GhostNV Driver Tests ===' &&
        echo 'Checking GhostNV source files:' &&
        find /ghost -name '*ghostnv*' -type f | head -10 &&
        echo &&
        echo 'Testing NVIDIA GPU access:' &&
        nvidia-smi || echo 'NVIDIA SMI not available' &&
        echo &&
        echo 'Checking CUDA capabilities:' &&
        nvcc --version || echo 'NVCC not available' &&
        echo &&
        echo 'Testing device nodes:' &&
        ls -la /dev/nvidia* || echo 'No NVIDIA devices found' &&
        echo '=== GhostNV tests complete ==='
    " 2>&1 | tee "$LOG_DIR/ghostnv_tests.log"
}

run_performance_tests() {
    log "Running performance tests..."
    
    cd "$GHOST_ROOT"
    
    # Performance testing
    docker-compose run --rm ghost-kernel-test bash -c "
        echo '=== Performance Tests ===' &&
        echo 'System Information:' &&
        lscpu | head -15 &&
        echo &&
        free -h &&
        echo &&
        echo 'GPU Information:' &&
        nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv || echo 'GPU info not available' &&
        echo &&
        echo 'Kernel build performance test:' &&
        cd /ghost/linux-ghost &&
        time zig build 2>&1 | tail -5 &&
        echo '=== Performance tests complete ==='
    " 2>&1 | tee "$LOG_DIR/performance_tests.log"
}

run_interactive_mode() {
    log "Starting interactive testing mode..."
    
    cd "$GHOST_ROOT"
    
    echo -e "${GREEN}Available commands in container:${NC}"
    echo "  - zig build                    # Build Ghost Kernel"
    echo "  - ./test_gpu.py               # Run GPU tests"
    echo "  - ./load_ghostnv.sh           # Load GhostNV driver"
    echo "  - nvidia-smi                  # Check GPU status"
    echo "  - ls zig-out/bin/             # Check built binaries"
    echo ""
    
    # Start interactive container
    docker-compose run --rm ghost-kernel-test bash
}

cleanup() {
    log "Cleaning up..."
    
    cd "$GHOST_ROOT"
    
    # Stop and remove containers
    docker-compose down || true
    
    # Remove dangling images (optional)
    # docker image prune -f
    
    success "Cleanup completed"
}

generate_report() {
    log "Generating test report..."
    
    REPORT_FILE="$LOG_DIR/ghost_kernel_test_report.md"
    
    cat > "$REPORT_FILE" << EOF
# Ghost Kernel Test Report

**Generated:** $(date)
**System:** $(uname -a)

## Test Environment

### Docker Configuration
- Container: $CONTAINER_NAME
- Image: $IMAGE_NAME

### GPU Information
\`\`\`
$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || echo "No GPU information available")
\`\`\`

## Test Results

### Kernel Compilation
$(if [ -f "$LOG_DIR/kernel_compilation.log" ]; then
    echo "✅ Completed - see kernel_compilation.log for details"
else
    echo "❌ Not run"
fi)

### Basic Tests
$(if [ -f "$LOG_DIR/basic_tests.log" ]; then
    echo "✅ Completed - see basic_tests.log for details"
else
    echo "❌ Not run"
fi)

### GhostNV Driver Tests
$(if [ -f "$LOG_DIR/ghostnv_tests.log" ]; then
    echo "✅ Completed - see ghostnv_tests.log for details"
else
    echo "❌ Not run"
fi)

### Performance Tests
$(if [ -f "$LOG_DIR/performance_tests.log" ]; then
    echo "✅ Completed - see performance_tests.log for details"
else
    echo "❌ Not run"
fi)

## Log Files
- Basic Tests: \`$LOG_DIR/basic_tests.log\`
- Kernel Compilation: \`$LOG_DIR/kernel_compilation.log\`
- GhostNV Tests: \`$LOG_DIR/ghostnv_tests.log\`
- Performance Tests: \`$LOG_DIR/performance_tests.log\`

## Next Steps
1. Review log files for detailed results
2. Fix any identified issues
3. Re-run specific tests as needed
4. Consider running interactive mode for detailed debugging

EOF

    success "Test report generated: $REPORT_FILE"
}

show_usage() {
    echo "Ghost Kernel Testing Runner"
    echo ""
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  check         Check system requirements"
    echo "  build         Build the Ghost Kernel container"
    echo "  test          Run all tests (compilation, basic, ghostnv, performance)"
    echo "  compile       Test kernel compilation only"
    echo "  basic         Run basic functionality tests"
    echo "  ghostnv       Run GhostNV driver tests"
    echo "  performance   Run performance tests"
    echo "  interactive   Start interactive testing mode"
    echo "  clean         Clean up containers and images"
    echo "  report        Generate test report"
    echo "  help          Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 check                    # Check if system is ready for testing"
    echo "  $0 build                    # Build the container"
    echo "  $0 test                     # Run all tests"
    echo "  $0 interactive              # Start interactive shell in container"
}

main() {
    case "${1:-help}" in
        check)
            check_requirements
            ;;
        build)
            check_requirements
            build_container
            ;;
        test)
            check_requirements
            build_container
            run_kernel_compilation_test
            run_basic_tests
            run_ghostnv_tests
            run_performance_tests
            generate_report
            ;;
        compile)
            run_kernel_compilation_test
            ;;
        basic)
            run_basic_tests
            ;;
        ghostnv)
            run_ghostnv_tests
            ;;
        performance)
            run_performance_tests
            ;;
        interactive)
            check_requirements
            run_interactive_mode
            ;;
        clean)
            cleanup
            ;;
        report)
            generate_report
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            error "Unknown command: $1"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi