"""Choose build concurrency within the host's CPU and memory limits."""
import os
import subprocess


def sysctl_number(name, fallback):
    try:
        return int(subprocess.check_output(
            ['sysctl', '-n', name], text=True, stderr=subprocess.DEVNULL,
        ).strip())
    except (OSError, ValueError, subprocess.CalledProcessError):
        return fallback


def build_resources(jobs=None):
    physical_cores = sysctl_number('hw.physicalcpu', os.cpu_count() or 4)
    memory_bytes = sysctl_number('hw.memsize', 16 * 1024 ** 3)
    # Reserve memory for Xcode and SwiftSyntax before budgeting Swift frontends.
    memory_jobs = max(1, int(memory_bytes / (1024 ** 3) - 4) // 3)
    return {
        'physical_cores': physical_cores,
        'memory_bytes': memory_bytes,
        'jobs': jobs if jobs is not None else max(1, min(8, physical_cores, memory_jobs)),
    }
