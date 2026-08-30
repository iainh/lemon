use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

use crate::config::{LABEL_PREFIX, ServiceConfig, Store, Workload, home_dir};
use crate::fsutil::atomic_write;
use crate::logs;
use crate::runtime::run_checked;

const CONTAINER_SYSTEM_JOB_NAME: &str = "_container-system";
const CONTAINER_SYSTEM_TIMEOUT_SECONDS: u64 = 60;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KeepAlive {
    Always(bool),
    UnsuccessfulExit,
}

#[derive(Debug, PartialEq, Eq)]
struct LaunchdJob {
    label: String,
    program_arguments: Vec<String>,
    run_at_load: bool,
    keep_alive: KeepAlive,
    process_type: &'static str,
    throttle_interval: u64,
    exit_timeout: u64,
    environment: Vec<(&'static str, String)>,
    standard_out_path: String,
    standard_error_path: String,
}

impl LaunchdJob {
    fn to_xml(&self) -> Result<Vec<u8>> {
        let mut output = String::from(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
             <plist version=\"1.0\">\n\
             <dict>\n",
        );
        write_key(&mut output, 1, "Label")?;
        write_string(&mut output, 1, &self.label)?;
        write_key(&mut output, 1, "ProgramArguments")?;
        write_indent(&mut output, 1);
        output.push_str("<array>\n");
        for argument in &self.program_arguments {
            write_string(&mut output, 2, argument)?;
        }
        write_indent(&mut output, 1);
        output.push_str("</array>\n");
        write_key(&mut output, 1, "RunAtLoad")?;
        write_boolean(&mut output, 1, self.run_at_load);
        write_key(&mut output, 1, "KeepAlive")?;
        match self.keep_alive {
            KeepAlive::Always(value) => write_boolean(&mut output, 1, value),
            KeepAlive::UnsuccessfulExit => {
                write_indent(&mut output, 1);
                output.push_str("<dict>\n");
                write_key(&mut output, 2, "SuccessfulExit")?;
                write_boolean(&mut output, 2, false);
                write_indent(&mut output, 1);
                output.push_str("</dict>\n");
            }
        }
        write_key(&mut output, 1, "ProcessType")?;
        write_string(&mut output, 1, self.process_type)?;
        write_key(&mut output, 1, "ThrottleInterval")?;
        write_integer(&mut output, 1, self.throttle_interval);
        write_key(&mut output, 1, "ExitTimeOut")?;
        write_integer(&mut output, 1, self.exit_timeout);
        if !self.environment.is_empty() {
            write_key(&mut output, 1, "EnvironmentVariables")?;
            write_indent(&mut output, 1);
            output.push_str("<dict>\n");
            for (key, value) in &self.environment {
                write_key(&mut output, 2, key)?;
                write_string(&mut output, 2, value)?;
            }
            write_indent(&mut output, 1);
            output.push_str("</dict>\n");
        }
        write_key(&mut output, 1, "StandardOutPath")?;
        write_string(&mut output, 1, &self.standard_out_path)?;
        write_key(&mut output, 1, "StandardErrorPath")?;
        write_string(&mut output, 1, &self.standard_error_path)?;
        output.push_str("</dict>\n</plist>\n");
        Ok(output.into_bytes())
    }
}

fn write_key(output: &mut String, depth: usize, key: &str) -> Result<()> {
    write_text_element(output, depth, "key", key)
}

fn write_string(output: &mut String, depth: usize, value: &str) -> Result<()> {
    write_text_element(output, depth, "string", value)
}

fn write_text_element(output: &mut String, depth: usize, tag: &str, value: &str) -> Result<()> {
    write_indent(output, depth);
    output.push('<');
    output.push_str(tag);
    output.push('>');
    write_xml_text(output, value)?;
    output.push_str("</");
    output.push_str(tag);
    output.push_str(">\n");
    Ok(())
}

fn write_xml_text(output: &mut String, value: &str) -> Result<()> {
    for character in value.chars() {
        if !is_xml_character(character) {
            bail!(
                "launchd value contains character U+{:04X}, which XML 1.0 does not allow",
                character as u32
            );
        }
        match character {
            '&' => output.push_str("&amp;"),
            '<' => output.push_str("&lt;"),
            '>' => output.push_str("&gt;"),
            _ => output.push(character),
        }
    }
    Ok(())
}

fn is_xml_character(character: char) -> bool {
    matches!(character, '\u{9}' | '\u{a}' | '\u{d}')
        || matches!(
            character,
            '\u{20}'..='\u{d7ff}' | '\u{e000}'..='\u{fffd}' | '\u{10000}'..='\u{10ffff}'
        )
}

fn write_boolean(output: &mut String, depth: usize, value: bool) {
    write_indent(output, depth);
    output.push_str(if value { "<true/>\n" } else { "<false/>\n" });
}

fn write_integer(output: &mut String, depth: usize, value: u64) {
    write_indent(output, depth);
    output.push_str("<integer>");
    output.push_str(&value.to_string());
    output.push_str("</integer>\n");
}

fn write_indent(output: &mut String, depth: usize) {
    for _ in 0..depth {
        output.push('\t');
    }
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
    Ok(home_dir()?
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
    let body = job(store, service, executable, runtime)?
        .to_xml()
        .context("failed to serialize LaunchAgent")?;
    atomic_write(&path, &body)?;
    Ok(path)
}

fn job(
    store: &Store,
    service: &ServiceConfig,
    executable: PathBuf,
    runtime: PathBuf,
) -> Result<LaunchdJob> {
    let log_dir = store.log_dir();
    let mut environment = vec![
        ("LEMON_CONFIG_DIR", path_string(&store.config_dir)?),
        ("LEMON_DATA_DIR", path_string(&store.data_dir)?),
        ("LEMON_RUNTIME", path_string(&runtime)?),
    ];
    if let Some(path) = std::env::var_os("PATH") {
        environment.push((
            "PATH",
            path.to_str().context("PATH is not valid UTF-8")?.to_owned(),
        ));
    }
    Ok(LaunchdJob {
        label: label(&service.name),
        program_arguments: vec![
            path_string(&executable)?,
            "run-service".into(),
            service.name.clone(),
        ],
        run_at_load: true,
        keep_alive: KeepAlive::Always(service.restart),
        process_type: "Background",
        throttle_interval: 5,
        exit_timeout: 15,
        environment,
        standard_out_path: path_string(&log_dir.join(format!("{}.log", service.name)))?,
        standard_error_path: path_string(&log_dir.join(format!("{}.error.log", service.name)))?,
    })
}

fn container_system_job(store: &Store, runtime: PathBuf) -> Result<LaunchdJob> {
    Ok(LaunchdJob {
        label: label(CONTAINER_SYSTEM_JOB_NAME),
        program_arguments: vec![
            path_string(&runtime)?,
            "system".into(),
            "start".into(),
            "--disable-kernel-install".into(),
            "--timeout".into(),
            CONTAINER_SYSTEM_TIMEOUT_SECONDS.to_string(),
        ],
        run_at_load: true,
        keep_alive: KeepAlive::UnsuccessfulExit,
        process_type: "Background",
        throttle_interval: 5,
        exit_timeout: 15,
        environment: Vec::new(),
        standard_out_path: path_string(&store.log_dir().join("container-system.log"))?,
        standard_error_path: path_string(&store.log_dir().join("container-system.error.log"))?,
    })
}

fn path_string(path: &Path) -> Result<String> {
    path.to_str()
        .map(str::to_owned)
        .with_context(|| format!("path is not valid UTF-8: {}", path.display()))
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
    if matches!(&service.workload, Workload::Container { .. }) {
        let runtime = runtime_executable(service)?;
        start_container_system_agent(store, runtime)?;
    }
    logs::rotate_service(store, service)?;
    let path = write_agent(store, service)?;
    bootstrap(&path)
}

fn start_container_system_agent(store: &Store, runtime: PathBuf) -> Result<()> {
    let path = agent_path(CONTAINER_SYSTEM_JOB_NAME)?;
    if path
        .symlink_metadata()
        .is_ok_and(|metadata| metadata.file_type().is_symlink())
    {
        if state(CONTAINER_SYSTEM_JOB_NAME)? == JobState::Stopped {
            bootstrap(&path)?;
        }
        return Ok(());
    }
    let loaded_runtime = loaded_program(CONTAINER_SYSTEM_JOB_NAME)?;
    if loaded_runtime
        .as_ref()
        .is_some_and(|loaded| loaded != &runtime)
    {
        stop(CONTAINER_SYSTEM_JOB_NAME)?;
    }
    let path = write_container_system_agent(store, runtime)?;
    if state(CONTAINER_SYSTEM_JOB_NAME)? == JobState::Stopped {
        bootstrap(&path)?;
    }
    Ok(())
}

fn write_container_system_agent(store: &Store, runtime: PathBuf) -> Result<PathBuf> {
    let log_dir = store.log_dir();
    fs::create_dir_all(&log_dir)
        .with_context(|| format!("failed to create {}", log_dir.display()))?;
    let path = agent_path(CONTAINER_SYSTEM_JOB_NAME)?;
    fs::create_dir_all(path.parent().expect("launch agent has a parent"))?;
    if path
        .symlink_metadata()
        .is_ok_and(|metadata| metadata.file_type().is_symlink())
    {
        return Ok(path);
    }
    let body = container_system_job(store, runtime)?
        .to_xml()
        .context("failed to serialize container system LaunchAgent")?;
    atomic_write(&path, &body)?;
    Ok(path)
}

fn bootstrap(path: &Path) -> Result<()> {
    run_checked(
        Command::new("launchctl")
            .arg("bootstrap")
            .arg(domain())
            .arg(path),
        "launchctl bootstrap",
    )
}

pub fn wait_for_container_system(runtime: &Path) -> Result<()> {
    if container_system_is_ready(runtime) {
        return Ok(());
    }

    let target = format!("{}/{}", domain(), label(CONTAINER_SYSTEM_JOB_NAME));
    let kickstart = Command::new("launchctl")
        .args(["kickstart", &target])
        .output()
        .context("failed to execute launchctl kickstart for the container system")?;
    let timeout = Duration::from_secs(CONTAINER_SYSTEM_TIMEOUT_SECONDS + 5);
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if container_system_is_ready(runtime) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(250));
    }

    let detail = String::from_utf8_lossy(&kickstart.stderr);
    if kickstart.status.success() {
        bail!("container system did not become ready within {timeout:?}");
    }
    bail!(
        "container system did not become ready within {timeout:?}; launchctl kickstart failed: {}",
        detail.trim()
    )
}

fn container_system_is_ready(runtime: &Path) -> bool {
    let Ok(mut child) = Command::new(runtime)
        .args(["system", "status"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Err(_) => return false,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
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

fn loaded_program(name: &str) -> Result<Option<PathBuf>> {
    let target = format!("{}/{}", domain(), label(name));
    let output = Command::new("launchctl")
        .args(["print", &target])
        .output()
        .context("failed to execute launchctl print")?;
    if !output.status.success() {
        return Ok(None);
    }
    let body = String::from_utf8_lossy(&output.stdout);
    Ok(body
        .lines()
        .find_map(|line| line.trim().strip_prefix("program = ").map(PathBuf::from)))
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

pub fn delete_container_system_if_unused(store: &Store) -> Result<()> {
    let container_agent_exists = store
        .list_services()?
        .into_iter()
        .filter(|service| matches!(service.workload, Workload::Container { .. }))
        .map(|service| agent_path(&service.name))
        .collect::<Result<Vec<_>>>()?
        .into_iter()
        .any(|path| path.exists());
    if !container_agent_exists {
        delete_container_system_agent()?;
    }
    Ok(())
}

fn delete_container_system_agent() -> Result<()> {
    let path = agent_path(CONTAINER_SYSTEM_JOB_NAME)?;
    if path
        .symlink_metadata()
        .is_ok_and(|metadata| metadata.file_type().is_symlink())
    {
        return Ok(());
    }
    delete(CONTAINER_SYSTEM_JOB_NAME)
}

pub fn reconcile(store: &Store) -> Result<(usize, usize)> {
    let services = store.list_services()?;
    let configured = services
        .iter()
        .map(|service| service.name.as_str())
        .collect::<HashSet<_>>();
    let installed = agent_names()?.into_iter().collect::<HashSet<_>>();
    let container_runtime = services
        .iter()
        .find(|service| {
            installed.contains(&service.name)
                && matches!(&service.workload, Workload::Container { .. })
        })
        .map(runtime_executable)
        .transpose()?;
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
    if let Some(runtime) = container_runtime {
        write_container_system_agent(store, runtime)?;
    } else {
        delete_container_system_agent()?;
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
    let name = path
        .file_name()?
        .to_str()?
        .strip_prefix(&format!("{LABEL_PREFIX}."))?
        .strip_suffix(".plist")?;
    (name != CONTAINER_SYSTEM_JOB_NAME).then(|| name.to_owned())
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
        assert_eq!(
            agent_name(Path::new("dev.lemon._container-system.plist")),
            None
        );
    }

    #[test]
    fn container_system_job_retries_only_failed_bootstraps() {
        let store = Store {
            config_dir: "/tmp/config".into(),
            data_dir: "/tmp/data".into(),
        };
        let job = container_system_job(&store, "/usr/local/bin/container".into()).unwrap();
        assert_eq!(job.label, "dev.lemon._container-system");
        assert_eq!(job.program_arguments[1], "system");
        assert_eq!(job.program_arguments[2], "start");
        assert_eq!(job.program_arguments[3], "--disable-kernel-install");
        assert_eq!(job.program_arguments[4], "--timeout");
        assert_eq!(job.program_arguments[5], "60");
        assert_eq!(job.keep_alive, KeepAlive::UnsuccessfulExit);
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
        let job = job(
            &store,
            &service,
            "/usr/local/bin/lemon".into(),
            "/usr/local/bin/container".into(),
        )
        .unwrap();
        assert_eq!(job.label, "dev.lemon.web");
        assert_eq!(job.keep_alive, KeepAlive::Always(true));
        assert_eq!(job.exit_timeout, 15);
        assert_eq!(job.program_arguments[1], "run-service");
        assert_eq!(job.program_arguments[2], "web");
        assert_eq!(
            job.environment
                .iter()
                .find_map(|(key, value)| (*key == "LEMON_RUNTIME").then_some(value.as_str())),
            Some("/usr/local/bin/container")
        );
        assert_eq!(
            job.environment.iter().find_map(|(key, value)| {
                (*key == "LEMON_CONFIG_DIR").then_some(value.as_str())
            }),
            Some("/tmp/config")
        );
    }

    #[test]
    fn launchd_job_xml_escapes_text_and_rejects_control_characters() {
        let store = Store {
            config_dir: "/tmp/config".into(),
            data_dir: "/tmp/data".into(),
        };
        let mut job = container_system_job(&store, "/usr/local/bin/container".into()).unwrap();
        job.label = "dev.lemon.<tea&biscuits>".into();

        let xml = String::from_utf8(job.to_xml().unwrap()).unwrap();

        assert!(xml.contains("dev.lemon.&lt;tea&amp;biscuits&gt;"));
        job.label.push('\u{1}');
        assert!(job.to_xml().unwrap_err().to_string().contains("U+0001"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn generated_launchd_jobs_are_valid_property_lists() {
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
        let jobs = [
            container_system_job(&store, "/usr/local/bin/container".into()).unwrap(),
            job(
                &store,
                &service,
                "/usr/local/bin/lemon".into(),
                "/usr/local/bin/container".into(),
            )
            .unwrap(),
        ];
        let temp = tempfile::tempdir().unwrap();
        for (index, job) in jobs.into_iter().enumerate() {
            let path = temp.path().join(format!("job-{index}.plist"));
            fs::write(&path, job.to_xml().unwrap()).unwrap();
            let output = Command::new("/usr/bin/plutil")
                .arg("-lint")
                .arg(&path)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "plutil rejected generated job: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
}
