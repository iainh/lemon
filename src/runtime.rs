use std::ffi::OsString;
use std::path::Path;
use std::process::{Command, ExitStatus};

use anyhow::{Context, Result, bail};

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

    for disk in &vm.disks {
        args.extend([
            "--device".into(),
            format!("virtio-blk,path={}", disk.display()).into(),
        ]);
    }
    args.extend(["--device".into(), "virtio-net,nat".into()]);
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
    prepare_vm(&vm)?;
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
    let error = match &service.workload {
        Workload::Vm { vm } => {
            let config = store.load_vm(vm)?;
            prepare_vm(&config)?;
            let log_path = store.log_dir().join(format!("vm-{vm}.log"));
            std::fs::create_dir_all(store.log_dir())?;
            Command::new("vfkit")
                .args(vfkit_args(&config, false, &log_path))
                .exec()
        }
        Workload::Container { .. } => Command::new("container")
            .args(container_args(&service)?)
            .exec(),
    };
    Err(error).context("failed to execute service runtime")
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
}
