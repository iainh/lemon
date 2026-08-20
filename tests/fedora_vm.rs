#![cfg(target_os = "macos")]

use std::fs::{self, File};
use std::io::{self, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use xz2::read::XzDecoder;

const SERVER_DOWNLOAD_PAGE: &str = "https://fedoraproject.org/server/download/";
const RELEASE_METADATA: &str = "https://fedoraproject.org/releases.json";
const VM_NAME: &str = "fedora-integration";
const SERVICE_NAME: &str = "fedora-integration-service";
const START_TIMEOUT: Duration = Duration::from_secs(90);
const BOOT_SETTLE_TIME: Duration = Duration::from_secs(30);

#[derive(Debug, Deserialize)]
struct Release {
    version: String,
    arch: String,
    link: String,
    variant: String,
    sha256: String,
}

struct ServiceGuard {
    lemon: PathBuf,
    home: PathBuf,
    active: bool,
}

impl Drop for ServiceGuard {
    fn drop(&mut self) {
        if self.active {
            let _ = Command::new(&self.lemon)
                .env("HOME", &self.home)
                .args(["service", "delete", SERVICE_NAME])
                .output();
            let _ = Command::new(&self.lemon)
                .env("HOME", &self.home)
                .args(["vm", "delete", VM_NAME])
                .output();
        }
    }
}

/// Downloads roughly 1.3 GB and expands to a multi-gigabyte raw disk before
/// booting a real VM with Virtualization.framework. Run explicitly with:
///
/// `cargo test --test fedora_vm -- --ignored --nocapture`
#[test]
#[ignore = "downloads and boots a full Fedora Server image"]
fn boots_current_fedora_server_aarch64_image() -> Result<()> {
    if std::env::consts::ARCH != "aarch64" {
        bail!("the Fedora aarch64 boot test requires Apple silicon");
    }
    require_tool("curl")?;
    require_tool("launchctl")?;
    require_tool("ssh")?;
    require_tool("ssh-keygen")?;
    require_tool("vfkit")?;

    let temp = tempfile::tempdir().context("failed to create test directory")?;
    let home = temp.path().join("home");
    fs::create_dir(&home)?;

    let page_path = temp.path().join("server-download.html");
    let metadata_path = temp.path().join("releases.json");
    download(SERVER_DOWNLOAD_PAGE, &page_path)?;
    download(RELEASE_METADATA, &metadata_path)?;

    let releases: Vec<Release> = serde_json::from_reader(File::open(&metadata_path)?)?;
    let release = releases
        .iter()
        .filter(|release| {
            release.arch == "aarch64"
                && release.variant == "Server"
                && release.link.ends_with(".aarch64.raw.xz")
        })
        .max_by_key(|release| release.version.parse::<u16>().unwrap_or_default())
        .context("Fedora metadata contains no Server aarch64 raw.xz image")?;
    let image_name = release
        .link
        .rsplit('/')
        .next()
        .context("Fedora image URL has no filename")?;
    let page = fs::read_to_string(&page_path)?;
    if !page.contains(image_name) {
        bail!("Fedora Server download page does not advertise {image_name}");
    }

    eprintln!(
        "Downloading Fedora {} from {}",
        release.version, release.link
    );
    let compressed = temp.path().join(image_name);
    download(&release.link, &compressed)?;
    let digest = sha256(&compressed)?;
    if digest != release.sha256 {
        bail!(
            "Fedora image checksum mismatch: expected {}, got {digest}",
            release.sha256
        );
    }

    let disk = temp.path().join("fedora-server.raw");
    eprintln!("Expanding {}", compressed.display());
    let input = BufReader::new(File::open(&compressed)?);
    let mut decoder = XzDecoder::new(input);
    let mut output = File::create(&disk)?;
    io::copy(&mut decoder, &mut output).context("failed to expand Fedora image")?;
    output.sync_all()?;

    let lemon = env!("CARGO_BIN_EXE_lemon");
    let private_key = temp.path().join("id_ed25519");
    run_checked(
        Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-f"])
            .arg(&private_key),
        "ssh-keygen",
    )?;
    let public_key = private_key.with_extension("pub");
    run_lemon(
        lemon,
        &home,
        [
            "vm",
            "create",
            VM_NAME,
            "--disk",
            disk.to_str().context("test path is not UTF-8")?,
            "--ssh-key",
            public_key.to_str().context("test path is not UTF-8")?,
            "--cpus",
            "2",
            "--memory",
            "4096",
        ],
    )?;
    run_lemon(
        lemon,
        &home,
        [
            "service",
            "create",
            "vm",
            SERVICE_NAME,
            "--vm",
            VM_NAME,
            "--no-restart",
        ],
    )?;
    let mut guard = ServiceGuard {
        lemon: lemon.into(),
        home: home.clone(),
        active: true,
    };

    run_lemon(lemon, &home, ["service", "start", SERVICE_NAME])?;
    let log_dir = home.join("Library/Application Support/dev.lemon.lemon/logs");
    let stderr_path = log_dir.join(format!("{SERVICE_NAME}.error.log"));
    wait_for_service_start(lemon, &home, &stderr_path)?;
    let starts = vfkit_start_count(&stderr_path);
    run_lemon(lemon, &home, ["service", "start", SERVICE_NAME])?;
    wait_for_additional_start(lemon, &home, &stderr_path, starts)?;
    eprintln!("Fedora VM started; observing it for {BOOT_SETTLE_TIME:?}");
    wait_while_service_running(lemon, &home, BOOT_SETTLE_TIME, &stderr_path)?;

    run_lemon(
        lemon,
        &home,
        [
            "vm",
            "ssh",
            VM_NAME,
            "-i",
            private_key.to_str().context("test path is not UTF-8")?,
            "--wait",
            "180",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "--",
            "true",
        ],
    )?;

    let efi_store = home
        .join("Library/Application Support/dev.lemon.lemon/vms")
        .join(VM_NAME)
        .join("efi-vars");
    let efi_size = fs::metadata(&efi_store)
        .with_context(|| {
            format!(
                "EFI variable store was not created at {}",
                efi_store.display()
            )
        })?
        .len();
    if efi_size == 0 {
        bail!("EFI variable store is empty");
    }

    run_lemon(lemon, &home, ["service", "stop", SERVICE_NAME])?;
    run_lemon(lemon, &home, ["service", "delete", SERVICE_NAME])?;
    run_lemon(lemon, &home, ["vm", "delete", VM_NAME])?;
    guard.active = false;
    let definition = home
        .join("Library/Application Support/dev.lemon.lemon/vms")
        .join(format!("{VM_NAME}.toml"));
    if definition.exists() {
        bail!("VM definition was not removed during teardown");
    }
    let service_definition = home
        .join("Library/Application Support/dev.lemon.lemon/services")
        .join(format!("{SERVICE_NAME}.toml"));
    if service_definition.exists() {
        bail!("service definition was not removed during teardown");
    }
    Ok(())
}

fn download(url: &str, destination: &Path) -> Result<()> {
    let status = Command::new("curl")
        .args(["--fail", "--location", "--retry", "3", "--output"])
        .arg(destination)
        .arg(url)
        .status()
        .with_context(|| format!("failed to execute curl for {url}"))?;
    if !status.success() {
        bail!("failed to download {url}: curl exited with {status}");
    }
    Ok(())
}

fn sha256(path: &Path) -> Result<String> {
    let mut file = BufReader::new(File::open(path)?);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 1024 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn run_lemon<const N: usize>(lemon: &str, home: &Path, args: [&str; N]) -> Result<()> {
    let output = Command::new(lemon)
        .env("HOME", home)
        .args(args)
        .output()
        .context("failed to execute Lemon")?;
    if !output.status.success() {
        bail!(
            "Lemon exited with {}:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

fn wait_for_service_start(lemon: &str, home: &Path, log_path: &Path) -> Result<()> {
    let deadline = Instant::now() + START_TIMEOUT;
    while Instant::now() < deadline {
        if service_state(lemon, home)?.contains(": running")
            && read_log(log_path).contains("virtual machine is running")
        {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(250));
    }
    bail!(
        "vfkit did not report a running VM within {START_TIMEOUT:?}:\n{}",
        read_log(log_path)
    )
}

fn wait_for_additional_start(
    lemon: &str,
    home: &Path,
    log_path: &Path,
    previous_starts: usize,
) -> Result<()> {
    let deadline = Instant::now() + START_TIMEOUT;
    while Instant::now() < deadline {
        if service_state(lemon, home)?.contains(": running")
            && vfkit_start_count(log_path) > previous_starts
        {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(250));
    }
    bail!(
        "launchd did not restart vfkit within {START_TIMEOUT:?}:\n{}",
        read_log(log_path)
    )
}

fn vfkit_start_count(path: &Path) -> usize {
    read_log(path).matches("virtual machine is running").count()
}

fn wait_while_service_running(
    lemon: &str,
    home: &Path,
    duration: Duration,
    log_path: &Path,
) -> Result<()> {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        let state = service_state(lemon, home)?;
        if !state.contains(": running") {
            bail!(
                "Fedora VM stopped during boot observation ({state}):\n{}",
                read_log(log_path)
            );
        }
        thread::sleep(Duration::from_millis(500));
    }
    Ok(())
}

fn service_state(lemon: &str, home: &Path) -> Result<String> {
    let output = Command::new(lemon)
        .env("HOME", home)
        .args(["service", "status", SERVICE_NAME])
        .output()
        .context("failed to query Lemon service")?;
    if !output.status.success() {
        bail!(
            "Lemon service status exited with {}:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn run_checked(command: &mut Command, description: &str) -> Result<()> {
    let status = command
        .status()
        .with_context(|| format!("failed to execute {description}"))?;
    if !status.success() {
        bail!("{description} exited with {status}");
    }
    Ok(())
}

fn read_log(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|error| format!("<failed to read log: {error}>"))
}

fn require_tool(name: &str) -> Result<PathBuf> {
    let path = std::env::var_os("PATH").context("PATH is not set")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
        .with_context(|| format!("required tool {name:?} was not found in PATH"))
}
