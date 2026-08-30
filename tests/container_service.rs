#![cfg(target_os = "macos")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

const SERVICE_A: &str = "container-integration-a";
const SERVICE_B: &str = "container-integration-b";
const SYSTEM_LABEL: &str = "dev.lemon._container-system";
const TIMEOUT: Duration = Duration::from_secs(30);

struct LaunchdGuard {
    lemon: PathBuf,
    home: PathBuf,
    path: String,
    active: bool,
}

impl Drop for LaunchdGuard {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        for service in [SERVICE_A, SERVICE_B] {
            let _ = lemon(
                &self.lemon,
                &self.home,
                &self.path,
                ["service", "delete", service],
            );
            bootout(&format!("dev.lemon.{service}"));
        }
        bootout(SYSTEM_LABEL);
    }
}

/// Loads short-lived fake jobs into the current user's launchd GUI domain. Run
/// explicitly with:
///
/// `cargo test --test container_service -- --ignored --nocapture`
#[test]
#[ignore = "loads temporary jobs into the current launchd GUI domain"]
fn supervises_container_system_and_workloads_as_launchd_services() -> Result<()> {
    require_unused_label(SYSTEM_LABEL)?;
    require_unused_label(&format!("dev.lemon.{SERVICE_A}"))?;
    require_unused_label(&format!("dev.lemon.{SERVICE_B}"))?;

    let temp = tempfile::tempdir().context("failed to create test directory")?;
    let home = temp.path().join("home");
    let bin = temp.path().join("bin");
    let state = temp.path().join("state");
    fs::create_dir_all(&home)?;
    fs::create_dir_all(&bin)?;
    fs::create_dir_all(&state)?;

    let runtime = bin.join("container");
    write_fake_runtime(&runtime, &state)?;
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").context("PATH is not set")?
    );
    let lemon_path = PathBuf::from(env!("CARGO_BIN_EXE_lemon"));
    let mut guard = LaunchdGuard {
        lemon: lemon_path.clone(),
        home: home.clone(),
        path: path.clone(),
        active: true,
    };

    for service in [SERVICE_A, SERVICE_B] {
        run_lemon(
            &lemon_path,
            &home,
            &path,
            ["service", "create", "container", service, "test-image"],
        )?;
    }
    for service in [SERVICE_A, SERVICE_B] {
        run_lemon(&lemon_path, &home, &path, ["service", "start", service])?;
    }

    let events = state.join("events");
    wait_until("runtime retry and both workloads", || {
        let body = read(&events);
        start_count(&body) >= 2
            && run_count(&body, SERVICE_A) >= 1
            && run_count(&body, SERVICE_B) >= 1
    })?;
    let body = read(&events);
    if body.contains("concurrent-system-start") || body.contains("run-before-ready") {
        bail!("invalid runtime interaction:\n{body}");
    }
    require_loaded(SYSTEM_LABEL)?;
    require_service_running(&lemon_path, &home, &path, SERVICE_A)?;
    require_service_running(&lemon_path, &home, &path, SERVICE_B)?;

    fs::remove_file(state.join("ready"))?;
    run_checked(
        Command::new("launchctl").args([
            "kill",
            "SIGTERM",
            &target(&format!("dev.lemon.{SERVICE_A}")),
        ]),
        "launchctl kill",
    )?;
    wait_until("runtime recovery and workload restart", || {
        let body = read(&events);
        start_count(&body) >= 3 && run_count(&body, SERVICE_A) >= 2
    })?;
    let body = read(&events);
    if body.contains("concurrent-system-start") || body.contains("run-before-ready") {
        bail!("invalid recovery interaction:\n{body}");
    }

    run_lemon(&lemon_path, &home, &path, ["service", "delete", SERVICE_A])?;
    require_loaded(SYSTEM_LABEL)?;
    let system_agent = home
        .join("Library/LaunchAgents")
        .join(format!("{SYSTEM_LABEL}.plist"));
    if !system_agent.exists() {
        bail!("container system agent was removed while a workload still used it");
    }

    run_lemon(&lemon_path, &home, &path, ["service", "delete", SERVICE_B])?;
    if system_agent.exists() || is_loaded(SYSTEM_LABEL) {
        bail!("container system agent remained after the last workload was deleted");
    }

    guard.active = false;
    Ok(())
}

fn write_fake_runtime(path: &Path, state: &Path) -> Result<()> {
    let body = format!(
        r#"#!/bin/sh
state={state:?}
events="$state/events"
case "$1:$2" in
  system:status)
    test -f "$state/ready"
    ;;
  system:start)
    echo "system-start $$" >> "$events"
    if ! mkdir "$state/system-starting" 2>/dev/null; then
      echo "concurrent-system-start" >> "$events"
      exit 70
    fi
    trap 'rmdir "$state/system-starting"' 0
    starts=$(grep -c '^system-start ' "$events")
    if test "$starts" -eq 1; then
      echo "initial-system-failure" >> "$events"
      exit 1
    fi
    sleep 1
    touch "$state/ready"
    ;;
  run:*)
    if ! test -f "$state/ready"; then
      echo "run-before-ready" >> "$events"
      exit 71
    fi
    shift
    name=unknown
    while test "$#" -gt 0; do
      if test "$1" = "--name"; then
        name=${{2#lemon-}}
        break
      fi
      shift
    done
    echo "run $name $$" >> "$events"
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
  *)
    echo "unexpected arguments: $*" >> "$events"
    exit 64
    ;;
esac
"#,
        state = state.display()
    );
    fs::write(path, body)?;
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions)?;
    Ok(())
}

fn require_service_running(lemon_path: &Path, home: &Path, path: &str, name: &str) -> Result<()> {
    let output = lemon(lemon_path, home, path, ["service", "status", name])?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() || !stdout.contains("state: running") {
        bail!(
            "service {name} is not running ({}):\n{}\n{}",
            output.status,
            stdout,
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

fn wait_until(description: &str, predicate: impl Fn() -> bool) -> Result<()> {
    let deadline = Instant::now() + TIMEOUT;
    while Instant::now() < deadline {
        if predicate() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    bail!("timed out waiting for {description}")
}

fn start_count(events: &str) -> usize {
    events
        .lines()
        .filter(|line| line.starts_with("system-start "))
        .count()
}

fn run_count(events: &str, service: &str) -> usize {
    events
        .lines()
        .filter(|line| line.starts_with(&format!("run {service} ")))
        .count()
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

fn run_lemon<const N: usize>(
    lemon_path: &Path,
    home: &Path,
    path: &str,
    args: [&str; N],
) -> Result<()> {
    let output = lemon(lemon_path, home, path, args)?;
    if !output.status.success() {
        bail!(
            "Lemon exited with {}:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}

fn lemon<const N: usize>(
    lemon_path: &Path,
    home: &Path,
    path: &str,
    args: [&str; N],
) -> Result<Output> {
    Command::new(lemon_path)
        .env("HOME", home)
        .env("PATH", path)
        .args(args)
        .output()
        .context("failed to execute Lemon")
}

fn require_unused_label(label: &str) -> Result<()> {
    if is_loaded(label) {
        bail!("launchd label {label:?} is already loaded; refusing to disturb it");
    }
    Ok(())
}

fn require_loaded(label: &str) -> Result<()> {
    if !is_loaded(label) {
        bail!("launchd label {label:?} is not loaded");
    }
    Ok(())
}

fn is_loaded(label: &str) -> bool {
    Command::new("launchctl")
        .args(["print", &target(label)])
        .output()
        .is_ok_and(|output| output.status.success())
}

fn bootout(label: &str) {
    let _ = Command::new("launchctl")
        .args(["bootout", &target(label)])
        .output();
}

fn target(label: &str) -> String {
    format!("gui/{}/{label}", unsafe { libc::getuid() })
}

fn run_checked(command: &mut Command, description: &str) -> Result<()> {
    let output = command
        .output()
        .with_context(|| format!("failed to execute {description}"))?;
    if !output.status.success() {
        bail!(
            "{description} exited with {}:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}
