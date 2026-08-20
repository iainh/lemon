use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::process::Command;

use anyhow::{Context, Result, bail};

use crate::config::{ServiceConfig, Store, VmConfig, Workload};
use crate::launchd::{self, JobState};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Resources {
    pub cpus: u32,
    pub memory_mib: u64,
}

impl std::ops::AddAssign for Resources {
    fn add_assign(&mut self, other: Self) {
        self.cpus += other.cpus;
        self.memory_mib += other.memory_mib;
    }
}

pub struct Admission {
    _lock: File,
}

pub fn limits() -> Result<Resources> {
    let host_cpus = std::thread::available_parallelism()
        .context("failed to determine host CPU count")?
        .get() as u32;
    let output = Command::new("sysctl")
        .args(["-n", "hw.memsize"])
        .output()
        .context("failed to query host memory with sysctl")?;
    if !output.status.success() {
        bail!("sysctl -n hw.memsize exited with {}", output.status);
    }
    let host_memory_bytes: u64 = String::from_utf8(output.stdout)?
        .trim()
        .parse()
        .context("sysctl returned an invalid host memory size")?;
    let defaults = Resources {
        cpus: host_cpus,
        memory_mib: host_memory_bytes / 1024 / 1024 * 4 / 5,
    };
    Ok(Resources {
        cpus: configured_limit("LEMON_MAX_CPUS", defaults.cpus)?,
        memory_mib: configured_limit("LEMON_MAX_MEMORY_MIB", defaults.memory_mib)?,
    })
}

pub fn allocated(store: &Store, exclude_service: Option<&str>) -> Result<Resources> {
    let mut allocated = Resources::default();
    for service in store.list_services()? {
        if exclude_service == Some(&service.name)
            || launchd::state(&service.name)? == JobState::Stopped
        {
            continue;
        }
        if let Workload::Vm { vm } = service.workload {
            allocated += resources(&store.load_vm(&vm)?);
        }
    }
    Ok(allocated)
}

pub fn admit(store: &Store, service: &ServiceConfig) -> Result<Option<Admission>> {
    let Workload::Vm { vm } = &service.workload else {
        return Ok(None);
    };
    let lock = admission_lock(store)?;
    let limits = limits()?;
    let allocated = allocated(store, Some(&service.name))?;
    let requested = resources(&store.load_vm(vm)?);
    ensure_available(limits, allocated, requested)?;
    Ok(Some(Admission { _lock: lock }))
}

pub fn ensure_vm_fits(vm: &VmConfig) -> Result<()> {
    ensure_available(limits()?, Resources::default(), resources(vm))
}

fn resources(vm: &VmConfig) -> Resources {
    Resources {
        cpus: vm.cpus.into(),
        memory_mib: vm.memory_mib.into(),
    }
}

fn ensure_available(limits: Resources, allocated: Resources, requested: Resources) -> Result<()> {
    if allocated.cpus + requested.cpus > limits.cpus {
        bail!(
            "VM needs {} CPUs, but {} of the {}-CPU Lemon limit are already allocated",
            requested.cpus,
            allocated.cpus,
            limits.cpus
        );
    }
    if allocated.memory_mib + requested.memory_mib > limits.memory_mib {
        bail!(
            "VM needs {} MiB, but {} MiB of the {} MiB Lemon memory limit are already allocated",
            requested.memory_mib,
            allocated.memory_mib,
            limits.memory_mib
        );
    }
    Ok(())
}

fn configured_limit<T>(name: &str, default: T) -> Result<T>
where
    T: std::str::FromStr + Copy + Default + PartialOrd + std::fmt::Display,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    std::env::var(name).map_or(Ok(default), |value| -> Result<T> {
        let value = value
            .parse()
            .with_context(|| format!("{name} must be a positive integer"))?;
        if value <= T::default() || value > default {
            bail!("{name} must be between 1 and the host default of {default}");
        }
        Ok(value)
    })
}

fn admission_lock(store: &Store) -> Result<File> {
    std::fs::create_dir_all(&store.data_dir)?;
    let path = store.data_dir.join("admission.lock");
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&path)
        .with_context(|| format!("failed to open {}", path.display()))?;
    // SAFETY: flock only reads the valid file descriptor and has no pointer arguments.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error()).context("failed to lock VM admission");
    }
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_cpu_and_memory_overcommit() {
        let limits = Resources {
            cpus: 8,
            memory_mib: 8192,
        };
        let allocated = Resources {
            cpus: 4,
            memory_mib: 4096,
        };
        assert!(
            ensure_available(
                limits,
                allocated,
                Resources {
                    cpus: 5,
                    memory_mib: 1024
                }
            )
            .unwrap_err()
            .to_string()
            .contains("CPU")
        );
        assert!(
            ensure_available(
                limits,
                allocated,
                Resources {
                    cpus: 2,
                    memory_mib: 4097
                }
            )
            .unwrap_err()
            .to_string()
            .contains("memory")
        );
    }
}
