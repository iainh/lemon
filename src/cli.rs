use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand};

use crate::config::{
    ServiceConfig, Store, VmBoot, VmConfig, Workload, generate_mac_address, validate_name,
};
use crate::{launchd, network, runtime};

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
    #[command(hide = true)]
    RunService { name: String },
}

#[derive(Debug, Subcommand)]
enum VmCommand {
    /// Define a VM backed by vfkit and Virtualization.framework.
    Create(VmCreate),
    /// List defined VMs.
    List,
    /// Run a VM in the foreground with an interactive serial console.
    Run { name: String },
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
    },
    /// Delete a VM definition (disk images are preserved).
    Delete { name: String },
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
    List,
    /// Install and start a service, or restart it if already loaded.
    Start { name: String },
    /// Stop and unload a service.
    Stop { name: String },
    /// Print whether launchd has the service loaded.
    Status { name: String },
    /// Delete a service definition and its LaunchAgent.
    Delete { name: String },
    /// Print the service's stdout and stderr log paths.
    Logs { name: String },
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
            CommandGroup::Doctor => doctor(),
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
            let status = runtime::run_vm(store, &name, true)?;
            if !status.success() {
                bail!("VM exited with {status}");
            }
        }
        VmCommand::Ssh {
            name,
            user,
            identity,
            wait,
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
            runtime::exec_ssh(&user, address, identity.as_deref())?;
        }
        VmCommand::Delete { name } => {
            let path = store.vm_path(&name);
            fs::remove_file(&path)
                .with_context(|| format!("VM {name:?} does not exist ({})", path.display()))?;
            println!("Deleted VM {name}; disk images were preserved");
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
        ServiceCommand::List => {
            println!("NAME\tTYPE\tSTATE\tRESTART");
            for service in store.list_services()? {
                let kind = match service.workload {
                    Workload::Vm { .. } => "vm",
                    Workload::Container { .. } => "container",
                };
                let state = if launchd::is_running(&service.name) {
                    "loaded"
                } else {
                    "stopped"
                };
                println!("{}\t{}\t{}\t{}", service.name, kind, state, service.restart);
            }
        }
        ServiceCommand::Start { name } => {
            let service = store.load_service(&name)?;
            launchd::start(store, &service)?;
            println!("Started service {name}");
        }
        ServiceCommand::Stop { name } => {
            store.load_service(&name)?;
            if launchd::is_running(&name) {
                launchd::stop(&name)?;
                println!("Stopped service {name}");
            } else {
                println!("Service {name} is already stopped");
            }
        }
        ServiceCommand::Status { name } => {
            store.load_service(&name)?;
            if launchd::is_running(&name) {
                println!("{name}: loaded");
            } else {
                println!("{name}: stopped");
            }
        }
        ServiceCommand::Delete { name } => {
            let path = store.service_path(&name);
            if !path.exists() {
                bail!("service {name:?} does not exist");
            }
            launchd::delete(&name)?;
            fs::remove_file(path)?;
            println!("Deleted service {name}");
        }
        ServiceCommand::Logs { name } => {
            let service = store.load_service(&name)?;
            println!(
                "stdout: {}",
                store.log_dir().join(format!("{name}.log")).display()
            );
            println!(
                "stderr: {}",
                store.log_dir().join(format!("{name}.error.log")).display()
            );
            if let Workload::Vm { vm } = service.workload {
                println!(
                    "guest:  {}",
                    store.log_dir().join(format!("vm-{vm}.log")).display()
                );
            }
        }
    }
    Ok(())
}

fn doctor() -> Result<()> {
    println!("Lemon runtime check");
    check_tool("launchctl", "built into macOS");
    check_tool("vfkit", "brew install vfkit");
    check_tool("container", "https://github.com/apple/container/releases");
    let arch = std::env::consts::ARCH;
    println!("  {:<12} {arch}", "architecture");
    if arch != "aarch64" {
        println!("               warning: Apple container requires Apple silicon");
    }
    Ok(())
}

fn check_tool(name: &str, install: &str) {
    let found = std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|dir| dir.join(name))
            .find(|path| path.is_file())
    });
    match found {
        Some(path) => println!("  {name:<12} {}", path.display()),
        None => println!("  {name:<12} missing ({install})"),
    }
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
