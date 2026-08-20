use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand};
use serde::Serialize;

use crate::capacity;
use crate::config::{
    ServiceConfig, Store, VmBoot, VmConfig, Workload, generate_mac_address, validate_name,
};
use crate::{launchd, logs, network, runtime};

#[derive(Debug, Parser)]
#[command(version, about, long_about = None, arg_required_else_help = true)]
pub struct Cli {
    #[command(subcommand)]
    command: CommandGroup,
}

#[derive(Debug, Subcommand)]
enum CommandGroup {
    /// Create and run Linux virtual machines.
    Vm {
        #[command(subcommand)]
        command: VmCommand,
    },
    /// Download OCI container images using Apple's native runtime.
    Container {
        #[command(subcommand)]
        command: ContainerCommand,
    },
    /// Manage launchd-supervised VM and container services.
    Service {
        #[command(subcommand)]
        command: ServiceCommand,
    },
    /// Check whether Lemon's native runtime dependencies are available.
    Doctor,
    /// Show VM resource limits and current launchd service allocations.
    Capacity {
        /// Print machine-readable JSON.
        #[arg(long)]
        json: bool,
    },
    #[command(hide = true)]
    RunService { name: String },
}

#[derive(Debug, Subcommand)]
enum VmCommand {
    /// Define a VM backed by vfkit and Virtualization.framework.
    Create(VmCreate),
    /// Clone a stopped VM using copy-on-write storage when available.
    Clone { source: String, name: String },
    /// List defined VMs.
    List,
    /// Run a VM in the foreground with an interactive serial console.
    Run { name: String },
    /// Wait until a running VM has a current DHCP lease and accepts SSH connections.
    Wait {
        name: String,
        #[arg(long, default_value_t = 120)]
        timeout: u64,
    },
    /// Log in to a running VM over SSH.
    Ssh {
        name: String,
        /// Override the cloud-init guest account.
        #[arg(long)]
        user: Option<String>,
        /// SSH private key. By default SSH uses its normal agent and key discovery.
        #[arg(short = 'i', long, value_name = "PATH")]
        identity: Option<PathBuf>,
        /// Seconds to wait for a DHCP lease and the SSH port.
        #[arg(long, default_value_t = 120)]
        wait: u64,
        /// An ssh_config option such as StrictHostKeyChecking=accept-new; repeat as needed.
        #[arg(short = 'o', long = "ssh-option", value_name = "OPTION")]
        ssh_options: Vec<String>,
        /// Optional command and arguments to run in the guest.
        #[arg(last = true)]
        command: Vec<String>,
    },
    /// Delete a VM definition.
    Delete {
        name: String,
        /// Also remove Lemon-managed state and cloned disks.
        #[arg(long)]
        purge: bool,
    },
}

#[derive(Debug, Args)]
struct VmCreate {
    name: String,
    /// Uncompressed Linux kernel image. Omit to use EFI boot.
    #[arg(long, value_name = "PATH")]
    kernel: Option<PathBuf>,
    /// Linux initramfs image.
    #[arg(long, requires = "kernel", value_name = "PATH")]
    initrd: Option<PathBuf>,
    /// Linux kernel command line.
    #[arg(long, requires = "kernel", default_value = "console=hvc0 rw")]
    cmdline: String,
    /// Raw disk image; repeat to attach multiple disks.
    #[arg(long, required = true, value_name = "PATH")]
    disk: Vec<PathBuf>,
    #[arg(long, default_value_t = 2, value_parser = clap::value_parser!(u8).range(1..))]
    cpus: u8,
    /// Memory in MiB.
    #[arg(long, default_value_t = 2048, value_parser = clap::value_parser!(u32).range(256..))]
    memory: u32,
    /// OpenSSH public key to authorize using cloud-init.
    #[arg(long, value_name = "PATH")]
    ssh_key: Option<PathBuf>,
    /// Guest account created when --ssh-key is supplied.
    #[arg(long, default_value = "lemon", requires = "ssh_key")]
    user: String,
}

#[derive(Debug, Subcommand)]
enum ContainerCommand {
    /// Pull an OCI image into Apple's native container image store.
    Pull {
        image: String,
        /// OCI platform such as linux/arm64.
        #[arg(long)]
        platform: Option<String>,
    },
}

#[derive(Debug, Subcommand)]
enum ServiceCommand {
    /// Define a launchd service.
    Create {
        #[command(subcommand)]
        workload: CreateService,
    },
    /// List defined services and their launchd state.
    List {
        /// Print machine-readable JSON.
        #[arg(long)]
        json: bool,
    },
    /// Install and start a service, or restart it if already loaded.
    Start {
        name: String,
        /// Wait this many seconds for a VM service to accept SSH connections.
        #[arg(long, value_name = "SECONDS")]
        wait: Option<u64>,
    },
    /// Stop and unload a service.
    Stop { name: String },
    /// Print whether launchd has the service loaded.
    Status {
        name: String,
        /// Print machine-readable JSON.
        #[arg(long)]
        json: bool,
    },
    /// Delete a service definition and its LaunchAgent.
    Delete {
        name: String,
        /// Also delete current and rotated service logs.
        #[arg(long)]
        purge_logs: bool,
    },
    /// Print the service's stdout and stderr log paths.
    Logs { name: String },
    /// Refresh LaunchAgents from definitions and remove orphaned Lemon agents.
    Reconcile,
}

#[derive(Debug, Subcommand)]
enum CreateService {
    /// Run a defined VM as a service.
    Vm {
        name: String,
        #[arg(long)]
        vm: String,
        /// Do not restart the workload when it exits.
        #[arg(long)]
        no_restart: bool,
    },
    /// Run an OCI container in an isolated lightweight VM.
    Container {
        name: String,
        image: String,
        #[arg(long)]
        cpus: Option<u8>,
        /// Memory with a suffix, for example 512M or 2G.
        #[arg(long)]
        memory: Option<String>,
        #[arg(short = 'e', long = "env", value_name = "KEY=VALUE")]
        env: Vec<String>,
        #[arg(short = 'p', long = "publish", value_name = "HOST:CONTAINER")]
        publish: Vec<String>,
        #[arg(short = 'v', long = "volume", value_name = "HOST:GUEST")]
        volumes: Vec<String>,
        #[arg(long)]
        no_restart: bool,
        /// Command and arguments passed to the container image.
        #[arg(last = true)]
        command: Vec<String>,
    },
}

impl Cli {
    pub fn run(self) -> Result<()> {
        let store = Store::discover()?;
        match self.command {
            CommandGroup::Vm { command } => run_vm(command, &store),
            CommandGroup::Container { command } => run_container(command),
            CommandGroup::Service { command } => run_service(command, &store),
            CommandGroup::Doctor => doctor(&store),
            CommandGroup::Capacity { json } => show_capacity(&store, json),
            CommandGroup::RunService { name } => runtime::exec_service(&store, &name),
        }
    }
}

fn run_vm(command: VmCommand, store: &Store) -> Result<()> {
    match command {
        VmCommand::Create(args) => {
            validate_name(&args.name)?;
            if store.vm_path(&args.name).exists() {
                bail!("VM {:?} already exists", args.name);
            }
            let disks = canonical_files(&args.disk)?;
            let boot = if let Some(kernel) = args.kernel {
                VmBoot::Linux {
                    kernel: canonical_file(&kernel)?,
                    initrd: args.initrd.map(|path| canonical_file(&path)).transpose()?,
                    cmdline: args.cmdline,
                }
            } else {
                VmBoot::Efi {
                    variable_store: store.efi_store_path(&args.name),
                }
            };
            let cloud_init = args
                .ssh_key
                .map(|path| {
                    let public_key = read_public_key(&path)?;
                    validate_guest_user(&args.user)?;
                    store.create_cloud_init(&args.name, &args.user, &public_key)
                })
                .transpose()?;
            store.save_vm(&VmConfig {
                name: args.name.clone(),
                cpus: args.cpus,
                memory_mib: args.memory,
                mac_address: Some(generate_mac_address()?),
                cloud_init,
                boot,
                disks,
            })?;
            println!("Created VM {}", args.name);
        }
        VmCommand::Clone { source, name } => {
            validate_name(&name)?;
            if store.vm_path(&name).exists() {
                bail!("VM {name:?} already exists");
            }
            let source = store.load_vm(&source)?;
            let _locks = runtime::acquire_vm_locks(store, &source)?;
            let clone = store.clone_vm(&source, &name)?;
            if let Err(error) = store.save_vm(&clone) {
                let _ = fs::remove_dir_all(store.vm_data_dir(&name));
                return Err(error);
            }
            println!("Cloned VM {} to {name}", source.name);
        }
        VmCommand::List => {
            println!("NAME\tCPUS\tMEMORY\tBOOT");
            for vm in store.list_vms()? {
                let boot = match vm.boot {
                    VmBoot::Linux { .. } => "linux",
                    VmBoot::Efi { .. } => "efi",
                };
                println!("{}\t{}\t{} MiB\t{}", vm.name, vm.cpus, vm.memory_mib, boot);
            }
        }
        VmCommand::Run { name } => {
            capacity::ensure_vm_fits(&store.load_vm(&name)?)?;
            let status = runtime::run_vm(store, &name, true)?;
            if !status.success() {
                bail!("VM exited with {status}");
            }
        }
        VmCommand::Wait { name, timeout } => {
            let address = wait_for_vm(store, &name, timeout)?;
            println!("{address}");
        }
        VmCommand::Ssh {
            name,
            user,
            identity,
            wait,
            ssh_options,
            command,
        } => {
            let vm = store.load_vm(&name)?;
            let mac_address = vm.mac_address.as_deref().context("VM has no MAC address")?;
            let user = user
                .or_else(|| {
                    vm.cloud_init
                        .as_ref()
                        .map(|cloud_init| cloud_init.user.clone())
                })
                .context("VM has no configured SSH user; pass --user")?;
            validate_guest_user(&user)?;
            let identity = identity.as_deref().map(canonical_file).transpose()?;
            let address = network::wait_for_ssh(mac_address, Duration::from_secs(wait))?;
            runtime::exec_ssh(&user, address, identity.as_deref(), &ssh_options, &command)?;
        }
        VmCommand::Delete { name, purge } => {
            if let Some(service) = store
                .list_services()?
                .into_iter()
                .find(|service| matches!(&service.workload, Workload::Vm { vm } if vm == &name))
            {
                bail!(
                    "cannot delete VM {name:?}; service {:?} still references it",
                    service.name
                );
            }
            let path = store.vm_path(&name);
            let _lock = path
                .exists()
                .then(|| runtime::acquire_vm_lock(store, &name))
                .transpose()?;
            fs::remove_file(&path)
                .with_context(|| format!("VM {name:?} does not exist ({})", path.display()))?;
            if purge {
                let directory = store.vm_data_dir(&name);
                if directory.exists() {
                    fs::remove_dir_all(&directory).with_context(|| {
                        format!("failed to remove VM data {}", directory.display())
                    })?;
                }
                println!("Deleted VM {name} and its Lemon-managed data");
            } else {
                println!("Deleted VM {name}; disk images and VM data were preserved");
            }
        }
    }
    Ok(())
}

fn run_container(command: ContainerCommand) -> Result<()> {
    match command {
        ContainerCommand::Pull { image, platform } => {
            let mut command = Command::new("container");
            command.args(["image", "pull"]);
            if let Some(platform) = platform {
                command.args(["--platform", &platform]);
            }
            command.arg(&image);
            runtime::run_checked(&mut command, "container image pull")?;
        }
    }
    Ok(())
}

fn run_service(command: ServiceCommand, store: &Store) -> Result<()> {
    launchd::ensure_macos()?;
    match command {
        ServiceCommand::Create { workload } => {
            let service = match workload {
                CreateService::Vm {
                    name,
                    vm,
                    no_restart,
                } => {
                    validate_name(&name)?;
                    store.load_vm(&vm)?;
                    ServiceConfig {
                        name,
                        restart: !no_restart,
                        workload: Workload::Vm { vm },
                    }
                }
                CreateService::Container {
                    name,
                    image,
                    cpus,
                    memory,
                    env,
                    publish,
                    volumes,
                    no_restart,
                    command,
                } => {
                    validate_name(&name)?;
                    ServiceConfig {
                        name,
                        restart: !no_restart,
                        workload: Workload::Container {
                            image,
                            cpus,
                            memory,
                            env,
                            publish,
                            volumes,
                            command,
                        },
                    }
                }
            };
            if store.service_path(&service.name).exists() {
                bail!("service {:?} already exists", service.name);
            }
            if let Workload::Vm { vm } = &service.workload {
                if let Some(existing) = store.list_services()?.into_iter().find(|candidate| {
                    matches!(&candidate.workload, Workload::Vm { vm: candidate_vm } if candidate_vm == vm)
                }) {
                    bail!(
                        "VM {vm:?} is already assigned to service {:?}",
                        existing.name
                    );
                }
            }
            store.save_service(&service)?;
            println!(
                "Created service {} (run `lemon service start {}`)",
                service.name, service.name
            );
        }
        ServiceCommand::List { json } => {
            let mut rows = Vec::new();
            for service in store.list_services()? {
                let status = launchd::status(&service.name)?;
                rows.push(ServiceStatusRow {
                    name: service.name,
                    kind: workload_kind(&service.workload),
                    state: status.state.as_str(),
                    pid: status.pid,
                    runs: status.runs,
                    restarts: status.runs.map(|runs| runs.saturating_sub(1)),
                    last_exit_code: status.last_exit_code,
                    restart: service.restart,
                    guest: None,
                });
            }
            if json {
                println!("{}", serde_json::to_string_pretty(&rows)?);
            } else {
                println!("NAME\tTYPE\tSTATE\tPID\tRESTARTS\tLAST-EXIT\tRESTART");
                for row in rows {
                    println!(
                        "{}\t{}\t{}\t{}\t{}\t{}\t{}",
                        row.name,
                        row.kind,
                        row.state,
                        display_option(row.pid),
                        display_option(row.restarts),
                        display_option(row.last_exit_code),
                        row.restart
                    );
                }
            }
        }
        ServiceCommand::Start { name, wait } => {
            let service = store.load_service(&name)?;
            if wait.is_some() && !matches!(service.workload, Workload::Vm { .. }) {
                bail!("--wait is only supported for VM services");
            }
            let _admission = capacity::admit(store, &service)?;
            launchd::start(store, &service)?;
            println!("Started service {name}");
            if let Some(timeout) = wait {
                let Workload::Vm { vm } = service.workload else {
                    unreachable!()
                };
                let address = wait_for_vm(store, &vm, timeout)?;
                println!("VM {vm} is ready at {address}");
            }
        }
        ServiceCommand::Stop { name } => {
            store.load_service(&name)?;
            if launchd::state(&name)? != launchd::JobState::Stopped {
                launchd::stop(&name)?;
                println!("Stopped service {name}");
            } else {
                println!("Service {name} is already stopped");
            }
        }
        ServiceCommand::Status { name, json } => {
            let service = store.load_service(&name)?;
            let status = launchd::status(&name)?;
            let mut guest = None;
            if status.state == launchd::JobState::Running {
                if let Workload::Vm { vm } = &service.workload {
                    let config = store.load_vm(vm)?;
                    let address = config
                        .mac_address
                        .as_deref()
                        .map(network::ssh_address)
                        .transpose()?
                        .flatten();
                    guest =
                        Some(address.map_or_else(
                            || "starting".into(),
                            |address| format!("ready ({address})"),
                        ));
                }
            }
            let row = ServiceStatusRow {
                name: service.name,
                kind: workload_kind(&service.workload),
                state: status.state.as_str(),
                pid: status.pid,
                runs: status.runs,
                restarts: status.runs.map(|runs| runs.saturating_sub(1)),
                last_exit_code: status.last_exit_code,
                restart: service.restart,
                guest,
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&row)?);
            } else {
                println!("state: {}", row.state);
                println!("pid: {}", display_option(row.pid));
                println!("runs: {}", display_option(row.runs));
                println!("last exit code: {}", display_option(row.last_exit_code));
                if let Some(guest) = row.guest {
                    println!("guest: {guest}");
                }
            }
        }
        ServiceCommand::Delete { name, purge_logs } => {
            let path = store.service_path(&name);
            if !path.exists() {
                bail!("service {name:?} does not exist");
            }
            let service = store.load_service(&name)?;
            launchd::delete(&name)?;
            if purge_logs {
                logs::purge_service(store, &service)?;
            }
            fs::remove_file(path)?;
            println!("Deleted service {name}");
        }
        ServiceCommand::Logs { name } => {
            let service = store.load_service(&name)?;
            let paths = store.service_log_paths(&service);
            println!("stdout: {}", paths[0].display());
            println!("stderr: {}", paths[1].display());
            if let Some(path) = paths.get(2) {
                println!("guest:  {}", path.display());
            }
        }
        ServiceCommand::Reconcile => {
            let (refreshed, removed) = launchd::reconcile(store)?;
            println!("Refreshed {refreshed} LaunchAgents; removed {removed} orphans");
        }
    }
    Ok(())
}

fn doctor(store: &Store) -> Result<()> {
    println!("Lemon runtime check");
    check_tool("launchctl", "built into macOS");
    check_vfkit();
    check_tool("ssh", "built into macOS");
    check_tool("container", "https://github.com/apple/container/releases");
    let arch = std::env::consts::ARCH;
    println!("  {:<12} {arch}", "architecture");
    if arch != "aarch64" {
        println!("               warning: Apple container requires Apple silicon");
    }
    for vm in store.list_vms()? {
        match runtime::validate_vm(&vm) {
            Ok(()) => println!("  vm {:<9} ready", vm.name),
            Err(error) => println!("  vm {:<9} invalid: {error}", vm.name),
        }
    }
    Ok(())
}

fn show_capacity(store: &Store, json: bool) -> Result<()> {
    let limits = capacity::limits()?;
    let allocated = capacity::allocated(store, None)?;
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "cpus": {
                    "allocated": allocated.cpus,
                    "limit": limits.cpus,
                    "available": limits.cpus.saturating_sub(allocated.cpus),
                },
                "memory_mib": {
                    "allocated": allocated.memory_mib,
                    "limit": limits.memory_mib,
                    "available": limits.memory_mib.saturating_sub(allocated.memory_mib),
                }
            }))?
        );
        return Ok(());
    }
    println!("RESOURCE\tALLOCATED\tLIMIT\tAVAILABLE");
    println!(
        "cpus\t{}\t{}\t{}",
        allocated.cpus,
        limits.cpus,
        limits.cpus.saturating_sub(allocated.cpus)
    );
    println!(
        "memory MiB\t{}\t{}\t{}",
        allocated.memory_mib,
        limits.memory_mib,
        limits.memory_mib.saturating_sub(allocated.memory_mib)
    );
    Ok(())
}

fn check_vfkit() {
    match find_tool("vfkit") {
        Some(path) => {
            println!("  {:<12} {}", "vfkit", path.display());
            if !runtime::supports_cloud_init(&path) {
                println!("               warning: vfkit 0.6.1 or newer is required for --ssh-key");
            }
        }
        None => println!("  {:<12} missing (brew install vfkit)", "vfkit"),
    }
}

fn check_tool(name: &str, install: &str) {
    match find_tool(name) {
        Some(path) => println!("  {name:<12} {}", path.display()),
        None => println!("  {name:<12} missing ({install})"),
    }
}

fn find_tool(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|dir| dir.join(name))
            .find(|path| path.is_file())
    })
}

fn canonical_files(paths: &[PathBuf]) -> Result<Vec<PathBuf>> {
    paths.iter().map(|path| canonical_file(path)).collect()
}

fn canonical_file(path: &Path) -> Result<PathBuf> {
    let canonical = path
        .canonicalize()
        .with_context(|| format!("{} does not exist", path.display()))?;
    if !canonical.is_file() {
        bail!("{} is not a file", canonical.display());
    }
    Ok(canonical)
}

fn read_public_key(path: &Path) -> Result<String> {
    let key = fs::read_to_string(path)
        .with_context(|| format!("failed to read SSH public key {}", path.display()))?;
    let key = key.trim();
    if key.is_empty() || key.contains(['\n', '\r']) || key.split_whitespace().count() < 2 {
        bail!("{} is not a single OpenSSH public key", path.display());
    }
    Ok(key.to_owned())
}

fn validate_guest_user(user: &str) -> Result<()> {
    let mut characters = user.chars();
    if !characters
        .next()
        .is_some_and(|character| character.is_ascii_alphanumeric() || character == '_')
        || !user
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '_' | '-'))
    {
        bail!(
            "invalid guest user {user:?}; use letters, numbers, '_' or '-', starting with a letter, number or '_'"
        );
    }
    Ok(())
}

fn wait_for_vm(store: &Store, name: &str, timeout: u64) -> Result<std::net::IpAddr> {
    let vm = store.load_vm(name)?;
    let mac_address = vm.mac_address.as_deref().context("VM has no MAC address")?;
    network::wait_for_ssh(mac_address, Duration::from_secs(timeout))
}

fn display_option<T: std::fmt::Display>(value: Option<T>) -> String {
    value.map_or_else(|| "-".into(), |value| value.to_string())
}

fn workload_kind(workload: &Workload) -> &'static str {
    match workload {
        Workload::Vm { .. } => "vm",
        Workload::Container { .. } => "container",
    }
}

#[derive(Serialize)]
struct ServiceStatusRow {
    name: String,
    #[serde(rename = "type")]
    kind: &'static str,
    state: &'static str,
    pid: Option<u32>,
    runs: Option<u64>,
    restarts: Option<u64>,
    last_exit_code: Option<i32>,
    restart: bool,
    guest: Option<String>,
}
