use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use plist::{Dictionary, Value};

use crate::config::{LABEL_PREFIX, ServiceConfig, Store, Workload};
use crate::fsutil::atomic_write;
use crate::logs;
use crate::runtime::run_checked;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Running,
    Loaded,
    Stopped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JobStatus {
    pub state: JobState,
    pub pid: Option<u32>,
    pub runs: Option<u64>,
    pub last_exit_code: Option<i32>,
}

impl JobState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Loaded => "loaded",
            Self::Stopped => "stopped",
        }
    }
}

pub fn label(name: &str) -> String {
    format!("{LABEL_PREFIX}.{name}")
}

pub fn agent_path(name: &str) -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home)
        .join("Library/LaunchAgents")
        .join(format!("{}.plist", label(name))))
}

pub fn write_agent(store: &Store, service: &ServiceConfig) -> Result<PathBuf> {
    let executable = std::env::current_exe().context("failed to locate the lemon executable")?;
    let log_dir = store.log_dir();
    fs::create_dir_all(&log_dir)
        .with_context(|| format!("failed to create {}", log_dir.display()))?;

    let path = agent_path(&service.name)?;
    fs::create_dir_all(path.parent().expect("launch agent has a parent"))?;
    let runtime = runtime_executable(service)?;
    let job = job_dictionary(store, service, executable, runtime);
    let mut body = Vec::new();
    plist::to_writer_xml(&mut body, &Value::Dictionary(job))
        .context("failed to serialize LaunchAgent")?;
    atomic_write(&path, &body)?;
    Ok(path)
}

fn job_dictionary(
    store: &Store,
    service: &ServiceConfig,
    executable: PathBuf,
    runtime: PathBuf,
) -> Dictionary {
    let log_dir = store.log_dir();
    let mut job = Dictionary::new();
    job.insert("Label".into(), Value::String(label(&service.name)));
    job.insert(
        "ProgramArguments".into(),
        Value::Array(vec![
            Value::String(executable.display().to_string()),
            Value::String("run-service".into()),
            Value::String(service.name.clone()),
        ]),
    );
    job.insert("RunAtLoad".into(), Value::Boolean(true));
    job.insert("KeepAlive".into(), Value::Boolean(service.restart));
    job.insert("ProcessType".into(), Value::String("Background".into()));
    job.insert("ThrottleInterval".into(), Value::Integer(5.into()));
    job.insert("ExitTimeOut".into(), Value::Integer(15.into()));
    let mut environment = Dictionary::new();
    environment.insert(
        "LEMON_CONFIG_DIR".into(),
        Value::String(store.config_dir.display().to_string()),
    );
    environment.insert(
        "LEMON_DATA_DIR".into(),
        Value::String(store.data_dir.display().to_string()),
    );
    environment.insert(
        "LEMON_RUNTIME".into(),
        Value::String(runtime.display().to_string()),
    );
    if let Some(path) = std::env::var_os("PATH") {
        environment.insert(
            "PATH".into(),
            Value::String(path.to_string_lossy().into_owned()),
        );
    }
    job.insert(
        "EnvironmentVariables".into(),
        Value::Dictionary(environment),
    );
    job.insert(
        "StandardOutPath".into(),
        Value::String(
            log_dir
                .join(format!("{}.log", service.name))
                .display()
                .to_string(),
        ),
    );
    job.insert(
        "StandardErrorPath".into(),
        Value::String(
            log_dir
                .join(format!("{}.error.log", service.name))
                .display()
                .to_string(),
        ),
    );
    job
}

fn runtime_executable(service: &ServiceConfig) -> Result<PathBuf> {
    let name = match service.workload {
        Workload::Vm { .. } => "vfkit",
        Workload::Container { .. } => "container",
    };
    find_executable(name)
        .with_context(|| format!("required runtime {name:?} was not found in PATH"))
}

fn find_executable(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|path| {
        std::env::split_paths(&path)
            .map(|directory| directory.join(name))
            .find(|candidate| is_executable(candidate))
    })
}

fn is_executable(path: &Path) -> bool {
    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

pub fn start(store: &Store, service: &ServiceConfig) -> Result<()> {
    if state(&service.name)? != JobState::Stopped {
        stop(&service.name)?;
    }
    logs::rotate_service(store, service)?;
    let path = write_agent(store, service)?;
    run_checked(
        Command::new("launchctl")
            .arg("bootstrap")
            .arg(domain())
            .arg(path),
        "launchctl bootstrap",
    )
}

pub fn stop(name: &str) -> Result<()> {
    let target = format!("{}/{}", domain(), label(name));
    run_checked(
        Command::new("launchctl").args(["bootout", &target]),
        "launchctl bootout",
    )?;
    let deadline = Instant::now() + Duration::from_secs(20);
    while state(name)? != JobState::Stopped {
        if Instant::now() >= deadline {
            bail!("launchd did not stop service {name:?} within 20 seconds");
        }
        thread::sleep(Duration::from_millis(100));
    }
    Ok(())
}

pub fn state(name: &str) -> Result<JobState> {
    Ok(status(name)?.state)
}

pub fn status(name: &str) -> Result<JobStatus> {
    let target = format!("{}/{}", domain(), label(name));
    let output = Command::new("launchctl")
        .args(["print", &target])
        .output()
        .context("failed to execute launchctl print")?;
    if !output.status.success() {
        return Ok(JobStatus {
            state: JobState::Stopped,
            pid: None,
            runs: None,
            last_exit_code: None,
        });
    }
    let body = String::from_utf8_lossy(&output.stdout);
    Ok(parse_job_status(&body))
}

fn parse_job_status(body: &str) -> JobStatus {
    let state = if job_is_running(body) {
        JobState::Running
    } else {
        JobState::Loaded
    };
    JobStatus {
        state,
        pid: parse_number(body, "pid"),
        runs: parse_number(body, "runs"),
        last_exit_code: parse_number(body, "last exit code"),
    }
}

fn job_is_running(body: &str) -> bool {
    body.lines().any(|line| line.trim() == "state = running")
}

fn parse_number<T: std::str::FromStr>(body: &str, name: &str) -> Option<T> {
    body.lines().find_map(|line| {
        let (key, value) = line.trim().split_once(" = ")?;
        (key == name).then(|| value.parse().ok()).flatten()
    })
}

pub fn delete(name: &str) -> Result<()> {
    if state(name)? != JobState::Stopped {
        stop(name)?;
    }
    let path = agent_path(name)?;
    if path.exists() {
        fs::remove_file(&path).with_context(|| format!("failed to remove {}", path.display()))?;
    }
    Ok(())
}

pub fn reconcile(store: &Store) -> Result<(usize, usize)> {
    let services = store.list_services()?;
    let configured = services
        .iter()
        .map(|service| service.name.as_str())
        .collect::<HashSet<_>>();
    let installed = agent_names()?.into_iter().collect::<HashSet<_>>();
    let mut removed = 0;
    for name in &installed {
        if !configured.contains(name.as_str()) {
            delete(name)?;
            removed += 1;
        }
    }
    let mut refreshed = 0;
    for service in services {
        if installed.contains(&service.name) {
            write_agent(store, &service)?;
            refreshed += 1;
        }
    }
    Ok((refreshed, removed))
}

fn agent_names() -> Result<Vec<String>> {
    let directory = agent_path("placeholder")?
        .parent()
        .expect("LaunchAgent has a parent")
        .to_path_buf();
    if !directory.exists() {
        return Ok(Vec::new());
    }
    Ok(fs::read_dir(&directory)
        .with_context(|| format!("failed to read {}", directory.display()))?
        .filter_map(|entry| entry.ok().and_then(|entry| agent_name(&entry.path())))
        .collect::<Vec<_>>())
}

fn agent_name(path: &Path) -> Option<String> {
    path.file_name()?
        .to_str()?
        .strip_prefix(&format!("{LABEL_PREFIX}."))?
        .strip_suffix(".plist")
        .map(str::to_owned)
}

fn domain() -> String {
    // SAFETY: getuid has no preconditions and does not dereference memory.
    format!("gui/{}", unsafe { libc::getuid() })
}

pub fn ensure_macos() -> Result<()> {
    if !cfg!(target_os = "macos") {
        bail!("launchd services are only supported on macOS");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Workload;

    #[test]
    fn labels_are_namespaced() {
        assert_eq!(label("web"), "dev.lemon.web");
    }

    #[test]
    fn distinguishes_a_running_job_from_a_loaded_job() {
        assert!(job_is_running("active count = 1\n\tstate = running\n"));
        assert!(!job_is_running("active count = 0\n\tstate = waiting\n"));
    }

    #[test]
    fn parses_launchd_process_details() {
        let status = parse_job_status(
            "active count = 1\n\tstate = running\n\truns = 3\n\tpid = 123\n\tlast exit code = 1\n",
        );
        assert_eq!(status.state, JobState::Running);
        assert_eq!(status.pid, Some(123));
        assert_eq!(status.runs, Some(3));
        assert_eq!(status.last_exit_code, Some(1));
    }

    #[test]
    fn recognizes_only_lemon_launch_agents() {
        assert_eq!(
            agent_name(Path::new("dev.lemon.web.plist")),
            Some("web".into())
        );
        assert_eq!(agent_name(Path::new("com.example.web.plist")), None);
        assert_eq!(agent_name(Path::new("dev.lemon.web.txt")), None);
    }

    #[test]
    fn job_executes_lemon_and_is_kept_alive() {
        let store = Store {
            config_dir: "/tmp/config".into(),
            data_dir: "/tmp/data".into(),
        };
        let service = ServiceConfig {
            name: "web".into(),
            restart: true,
            workload: Workload::Container {
                image: "nginx:latest".into(),
                cpus: None,
                memory: None,
                env: vec![],
                publish: vec![],
                volumes: vec![],
                command: vec![],
            },
        };
        let job = job_dictionary(
            &store,
            &service,
            "/usr/local/bin/lemon".into(),
            "/usr/local/bin/container".into(),
        );
        assert_eq!(job["Label"].as_string(), Some("dev.lemon.web"));
        assert_eq!(job["KeepAlive"].as_boolean(), Some(true));
        assert_eq!(job["ExitTimeOut"].as_signed_integer(), Some(15));
        let args = job["ProgramArguments"].as_array().unwrap();
        assert_eq!(args[1].as_string(), Some("run-service"));
        assert_eq!(args[2].as_string(), Some("web"));
        let environment = job["EnvironmentVariables"].as_dictionary().unwrap();
        assert_eq!(
            environment["LEMON_RUNTIME"].as_string(),
            Some("/usr/local/bin/container")
        );
        assert_eq!(
            environment["LEMON_CONFIG_DIR"].as_string(),
            Some("/tmp/config")
        );
    }
}
