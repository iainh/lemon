use std::ffi::OsString;
use std::fs::{File, OpenOptions};
use std::net::IpAddr;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::process::{Command, ExitStatus};

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};

use crate::config::{ServiceConfig, Store, VmBoot, VmConfig, Workload};

pub fn vfkit_args(vm: &VmConfig, interactive: bool, log_path: &Path) -> Vec<OsString> {
    let mut args = vec![
        "--cpus".into(),
        vm.cpus.to_string().into(),
        "--memory".into(),
        vm.memory_mib.to_string().into(),
    ];

    let bootloader = match &vm.boot {
        VmBoot::Linux {
            kernel,
            initrd,
            cmdline,
        } => {
            let mut value = format!("linux,kernel={}", kernel.display());
            if let Some(initrd) = initrd {
                value.push_str(&format!(",initrd={}", initrd.display()));
            }
            value.push_str(&format!(",cmdline={cmdline:?}"));
            value
        }
        VmBoot::Efi { variable_store } => {
            format!("efi,variable-store={},create", variable_store.display())
        }
    };
    args.extend(["--bootloader".into(), bootloader.into()]);

    if let Some(cloud_init) = &vm.cloud_init {
        args.extend([
            "--cloud-init".into(),
            format!(
                "{},{}",
                cloud_init.user_data.display(),
                cloud_init.meta_data.display()
            )
            .into(),
        ]);
    }

    for disk in &vm.disks {
        args.extend([
            "--device".into(),
            format!("virtio-blk,path={}", disk.display()).into(),
        ]);
    }
    let network = vm.mac_address.as_ref().map_or_else(
        || "virtio-net,nat".to_owned(),
        |mac| format!("virtio-net,nat,mac={mac}"),
    );
    args.extend(["--device".into(), network.into()]);
    args.extend([
        "--device".into(),
        if interactive {
            "virtio-serial,stdio".into()
        } else {
            format!("virtio-serial,logFilePath={}", log_path.display()).into()
        },
    ]);
    args
}

pub fn container_args(service: &ServiceConfig) -> Result<Vec<OsString>> {
    let Workload::Container {
        image,
        cpus,
        memory,
        env,
        publish,
        volumes,
        command,
    } = &service.workload
    else {
        bail!("service {:?} is not a container", service.name);
    };

    let mut args: Vec<OsString> = vec![
        "run".into(),
        "--rm".into(),
        "--name".into(),
        format!("lemon-{}", service.name).into(),
    ];
    if let Some(cpus) = cpus {
        args.extend(["--cpus".into(), cpus.to_string().into()]);
    }
    if let Some(memory) = memory {
        args.extend(["--memory".into(), memory.into()]);
    }
    for value in env {
        args.extend(["--env".into(), value.into()]);
    }
    for value in publish {
        args.extend(["--publish".into(), value.into()]);
    }
    for value in volumes {
        args.extend(["--volume".into(), value.into()]);
    }
    args.push(image.into());
    args.extend(command.iter().map(Into::into));
    Ok(args)
}

pub fn run_vm(store: &Store, name: &str, interactive: bool) -> Result<ExitStatus> {
    let vm = store.load_vm(name)?;
    validate_vm(&vm)?;
    if vm.cloud_init.is_some() {
        ensure_cloud_init_support(Path::new("vfkit"))?;
    }
    prepare_vm(&vm)?;
    let _locks = acquire_vm_locks(store, &vm)?;
    let log_path = store.log_dir().join(format!("vm-{name}.log"));
    std::fs::create_dir_all(store.log_dir()).context("failed to create log directory")?;
    let args = vfkit_args(&vm, interactive, &log_path);
    Command::new("vfkit")
        .args(args)
        .status()
        .context("failed to start vfkit; install it with `brew install vfkit`")
}

pub fn exec_service(store: &Store, name: &str) -> Result<()> {
    use std::os::unix::process::CommandExt;

    let service = store.load_service(name)?;
    let runtime = std::env::var_os("LEMON_RUNTIME");
    let error = match &service.workload {
        Workload::Vm { vm } => {
            let config = store.load_vm(vm)?;
            validate_vm(&config)?;
            let runtime = runtime.as_deref().unwrap_or_else(|| "vfkit".as_ref());
            if config.cloud_init.is_some() {
                ensure_cloud_init_support(Path::new(runtime))?;
            }
            prepare_vm(&config)?;
            let locks = acquire_vm_locks(store, &config)?;
            preserve_locks_across_exec(&locks)?;
            let log_path = store.log_dir().join(format!("vm-{vm}.log"));
            std::fs::create_dir_all(store.log_dir())?;
            Command::new(runtime)
                .args(vfkit_args(&config, false, &log_path))
                .exec()
        }
        Workload::Container { .. } => {
            Command::new(runtime.as_deref().unwrap_or_else(|| "container".as_ref()))
                .args(container_args(&service)?)
                .exec()
        }
    };
    Err(error).context("failed to execute service runtime")
}

pub fn supports_cloud_init(executable: &Path) -> bool {
    Command::new(executable)
        .arg("--help")
        .output()
        .is_ok_and(|output| {
            String::from_utf8_lossy(&output.stdout).contains("--cloud-init")
                || String::from_utf8_lossy(&output.stderr).contains("--cloud-init")
        })
}

fn ensure_cloud_init_support(executable: &Path) -> Result<()> {
    if !supports_cloud_init(executable) {
        bail!(
            "{} does not support --cloud-init; install vfkit 0.6.1 or newer",
            executable.display()
        );
    }
    Ok(())
}

pub fn exec_ssh(
    user: &str,
    address: IpAddr,
    identity: Option<&Path>,
    options: &[String],
    remote_command: &[String],
) -> Result<()> {
    use std::os::unix::process::CommandExt;

    let mut command = Command::new("ssh");
    if let Some(identity) = identity {
        command.args(["-i".as_ref(), identity.as_os_str()]);
    }
    for option in options {
        command.args(["-o", option]);
    }
    let error = command
        .arg(format!("{user}@{address}"))
        .args(remote_command)
        .exec();
    Err(error).context("failed to execute ssh")
}

fn prepare_vm(vm: &VmConfig) -> Result<()> {
    if let VmBoot::Efi { variable_store } = &vm.boot {
        if let Some(parent) = variable_store.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("failed to create EFI state directory {}", parent.display())
            })?;
        }
    }
    Ok(())
}

pub fn validate_vm(vm: &VmConfig) -> Result<()> {
    for disk in &vm.disks {
        validate_regular_file(disk, "VM disk")?;
    }
    match &vm.boot {
        VmBoot::Linux { kernel, initrd, .. } => {
            validate_regular_file(kernel, "Linux kernel")?;
            if let Some(initrd) = initrd {
                validate_regular_file(initrd, "Linux initrd")?;
            }
        }
        VmBoot::Efi { .. } => {}
    }
    if let Some(cloud_init) = &vm.cloud_init {
        validate_regular_file(&cloud_init.user_data, "cloud-init user data")?;
        validate_regular_file(&cloud_init.meta_data, "cloud-init metadata")?;
    }
    Ok(())
}

fn validate_regular_file(path: &Path, description: &str) -> Result<()> {
    if !path.metadata().is_ok_and(|metadata| metadata.is_file()) {
        bail!(
            "{description} is missing or is not a file: {}",
            path.display()
        );
    }
    Ok(())
}

pub(crate) fn acquire_vm_lock(store: &Store, name: &str) -> Result<File> {
    let path = store.vm_lock_path(name);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create VM state directory {}", parent.display()))?;
    }
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&path)
        .with_context(|| format!("failed to open VM lock {}", path.display()))?;
    // SAFETY: flock only reads the valid file descriptor and has no pointer arguments.
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::WouldBlock {
            bail!("VM {name:?} is already running");
        }
        return Err(error).context("failed to lock VM");
    }
    Ok(file)
}

pub(crate) fn acquire_vm_locks(store: &Store, vm: &VmConfig) -> Result<Vec<File>> {
    let mut locks = vec![acquire_vm_lock(store, &vm.name)?];
    let mut disks = vm.disks.iter().collect::<Vec<_>>();
    disks.sort();
    disks.dedup();
    for disk in disks {
        let identity = disk
            .canonicalize()
            .with_context(|| format!("failed to resolve VM disk {}", disk.display()))?;
        let digest = Sha256::digest(identity.as_os_str().as_bytes());
        let path = store
            .data_dir
            .join("disk-locks")
            .join(format!("{digest:x}.lock"));
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("failed to create disk lock directory {}", parent.display())
            })?;
        }
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&path)
            .with_context(|| format!("failed to open VM disk lock {}", path.display()))?;
        lock_file(&file).with_context(|| {
            format!(
                "VM disk {} is already in use by another Lemon VM",
                disk.display()
            )
        })?;
        locks.push(file);
    }
    Ok(locks)
}

fn lock_file(file: &File) -> Result<()> {
    // SAFETY: flock only reads the valid file descriptor and has no pointer arguments.
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result != 0 {
        return Err(std::io::Error::last_os_error()).context("failed to lock file");
    }
    Ok(())
}

fn preserve_locks_across_exec(files: &[File]) -> Result<()> {
    for file in files {
        preserve_lock_across_exec(file)?;
    }
    Ok(())
}

fn preserve_lock_across_exec(file: &File) -> Result<()> {
    let descriptor = file.as_raw_fd();
    // SAFETY: fcntl only operates on the valid descriptor and uses integer arguments here.
    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
    if flags == -1
        || unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags & !libc::FD_CLOEXEC) } == -1
    {
        return Err(std::io::Error::last_os_error()).context("failed to preserve VM lock");
    }
    Ok(())
}

pub fn run_checked(command: &mut Command, description: &str) -> Result<()> {
    let status = command
        .status()
        .with_context(|| format!("failed to run {description}"))?;
    if !status.success() {
        bail!("{description} exited with {status}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{ServiceConfig, Workload};

    #[test]
    fn builds_container_arguments_without_a_shell() {
        let service = ServiceConfig {
            name: "web".into(),
            restart: true,
            workload: Workload::Container {
                image: "nginx:latest".into(),
                cpus: Some(2),
                memory: Some("512M".into()),
                env: vec!["GREETING=hello world".into()],
                publish: vec!["8080:80".into()],
                volumes: vec!["/tmp/site:/site".into()],
                command: vec!["nginx".into(), "-g".into(), "daemon off;".into()],
            },
        };
        let args = container_args(&service).unwrap();
        assert_eq!(args.first().unwrap(), "run");
        assert!(args.contains(&OsString::from("GREETING=hello world")));
        assert_eq!(args.last().unwrap(), "daemon off;");
    }

    #[test]
    fn prevents_two_processes_from_opening_the_same_vm() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store {
            config_dir: temp.path().join("config"),
            data_dir: temp.path().join("data"),
        };
        let _lock = acquire_vm_lock(&store, "dev").unwrap();
        let error = acquire_vm_lock(&store, "dev").unwrap_err();
        assert!(error.to_string().contains("already running"));
    }

    #[test]
    fn prevents_two_vms_from_using_the_same_writable_disk() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store {
            config_dir: temp.path().join("config"),
            data_dir: temp.path().join("data"),
        };
        let disk = temp.path().join("disk.raw");
        std::fs::write(&disk, []).unwrap();
        let vm = |name: &str| VmConfig {
            name: name.into(),
            cpus: 1,
            memory_mib: 512,
            mac_address: None,
            cloud_init: None,
            boot: VmBoot::Efi {
                variable_store: temp.path().join(format!("{name}.efi")),
            },
            disks: vec![disk.clone()],
        };

        let _locks = acquire_vm_locks(&store, &vm("first")).unwrap();
        let error = acquire_vm_locks(&store, &vm("second")).unwrap_err();

        assert!(error.to_string().contains("already in use"));
        assert!(error.to_string().contains("disk.raw"));
    }

    #[test]
    fn validates_all_vm_runtime_files() {
        let temp = tempfile::tempdir().unwrap();
        let disk = temp.path().join("disk.raw");
        let kernel = temp.path().join("kernel");
        std::fs::write(&disk, []).unwrap();
        std::fs::write(&kernel, []).unwrap();
        let mut vm = VmConfig {
            name: "dev".into(),
            cpus: 1,
            memory_mib: 512,
            mac_address: None,
            cloud_init: None,
            boot: VmBoot::Linux {
                kernel,
                initrd: None,
                cmdline: String::new(),
            },
            disks: vec![disk],
        };
        assert!(validate_vm(&vm).is_ok());
        vm.disks[0] = temp.path().join("missing.raw");
        assert!(
            validate_vm(&vm)
                .unwrap_err()
                .to_string()
                .contains("VM disk")
        );
    }
}
