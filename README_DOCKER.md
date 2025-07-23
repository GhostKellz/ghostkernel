# Ghost Kernel Docker Testing Environment

This directory contains a comprehensive Docker-based testing environment for the Ghost Kernel and GhostNV NVIDIA driver.

## 🚀 Quick Start

### Prerequisites

1. **Docker** with NVIDIA Container Runtime support
2. **NVIDIA GPU** with compatible drivers
3. **NVIDIA Container Toolkit** installed

```bash
# Install NVIDIA Container Toolkit (Ubuntu/Debian)
curl -s -L https://nvidia.github.io/nvidia-container-runtime/gpgkey | sudo apt-key add -
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-container-runtime/$distribution/nvidia-container-runtime.list | sudo tee /etc/apt/sources.list.d/nvidia-container-runtime.list
sudo apt-get update && sudo apt-get install -y nvidia-container-runtime
sudo systemctl restart docker
```

### Running Tests

```bash
# Check system requirements
./test_runner.sh check

# Build the container and run all tests
./test_runner.sh test

# Run specific test suites
./test_runner.sh compile    # Kernel compilation only
./test_runner.sh ghostnv    # GhostNV driver tests
./test_runner.sh basic      # Basic functionality tests

# Interactive development mode
./test_runner.sh interactive
```

## 📋 Available Commands

| Command | Description |
|---------|-------------|
| `check` | Verify system requirements |
| `build` | Build the Ghost Kernel container |
| `test` | Run complete test suite |
| `compile` | Test kernel compilation |
| `basic` | Run basic functionality tests |
| `ghostnv` | Test GhostNV driver |
| `performance` | Run performance benchmarks |
| `interactive` | Start interactive shell |
| `clean` | Clean up containers |
| `report` | Generate test report |

## 🐳 Container Architecture

### Services

- **ghost-kernel-test**: Main testing container with full GPU access
- **ghost-kernel-dev**: Development container for interactive work

### Key Features

- **NVIDIA GPU Support**: Full GPU access with CUDA toolkit
- **Privileged Mode**: Required for kernel module testing
- **Device Access**: Direct access to NVIDIA devices
- **Volume Mounts**: Source code, logs, and cache persistence

## 🧪 Testing Capabilities

### Kernel Testing
- ✅ Ghost Kernel compilation with Zig 0.15
- ✅ Binary generation verification
- ✅ Build system validation
- ✅ Error reporting and logging

### GhostNV Driver Testing
- ✅ NVIDIA GPU detection
- ✅ CUDA capability verification
- ✅ Device node access
- ✅ Driver source validation

### Performance Testing
- ✅ Compilation time benchmarks
- ✅ GPU utilization monitoring
- ✅ Memory usage analysis
- ✅ System resource tracking

## 📁 File Structure

```
ghostkernel/
├── Dockerfile              # Main container definition
├── docker-compose.yml      # Multi-service configuration
├── test_runner.sh          # Comprehensive test runner
├── .dockerignore           # Docker build exclusions
└── logs/                   # Test outputs and reports
    ├── basic_tests.log
    ├── kernel_compilation.log
    ├── ghostnv_tests.log
    ├── performance_tests.log
    └── ghost_kernel_test_report.md
```

## 🔧 Advanced Usage

### Custom Testing

```bash
# Run specific kernel builds
docker-compose run --rm ghost-kernel-test bash -c "
    cd /ghost/linux-ghost && 
    zig build -Dgaming=true -Dgpu=true
"

# Monitor GPU during tests
docker-compose run --rm ghost-kernel-test bash -c "
    watch -n 1 nvidia-smi
"

# Debug compilation issues
docker-compose run --rm ghost-kernel-test bash -c "
    cd /ghost/linux-ghost && 
    zig build --verbose 2>&1 | tee /ghost/logs/debug.log
"
```

### Development Mode

```bash
# Start development container
docker-compose --profile dev run --rm ghost-kernel-dev

# Inside container:
cd /ghost/linux-ghost
zig build --verbose
./test_gpu.py
nvidia-smi
```

### Log Analysis

```bash
# View all logs
ls -la logs/

# Watch real-time compilation
tail -f logs/kernel_compilation.log

# Check test results
cat logs/ghost_kernel_test_report.md
```

## 🚨 Troubleshooting

### Common Issues

1. **NVIDIA Runtime Not Found**
   ```bash
   # Check Docker runtime
   docker info | grep nvidia
   # If not found, reinstall NVIDIA Container Toolkit
   ```

2. **GPU Not Accessible**
   ```bash
   # Test GPU access
   docker run --rm --gpus all nvidia/cuda:12.6-base nvidia-smi
   ```

3. **Container Build Fails**
   ```bash
   # Clean build with no cache
   docker-compose build --no-cache
   ```

4. **Kernel Compilation Errors**
   ```bash
   # Check Zig version in container
   docker-compose run --rm ghost-kernel-test zig version
   ```

### Debug Mode

```bash
# Enable verbose logging
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain

# Run with debug output
./test_runner.sh test 2>&1 | tee debug_output.log
```

## 📊 Performance Expectations

### Build Times (approximate)
- Container build: 5-10 minutes
- Kernel compilation: 30-60 seconds
- Full test suite: 2-5 minutes

### Resource Usage
- RAM: 2-4 GB during compilation
- Disk: ~2 GB for container image
- GPU: Minimal (detection/testing only)

## 🎯 Next Steps

1. **Run initial tests**: `./test_runner.sh test`
2. **Review logs**: Check `logs/` directory
3. **Interactive debugging**: `./test_runner.sh interactive`
4. **Performance tuning**: Monitor resource usage
5. **CI/CD Integration**: Adapt scripts for automation

## 🤝 Contributing

To add new tests or improve the testing environment:

1. Modify `test_runner.sh` for new test commands
2. Update `Dockerfile` for additional dependencies
3. Extend `docker-compose.yml` for new services
4. Add test scripts to the container

## 📝 Notes

- Container runs in privileged mode for kernel development
- GPU access requires NVIDIA Container Toolkit
- All source code is mounted for live development
- Logs persist between container runs
- Interactive mode provides full development environment