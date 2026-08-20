use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

use anyhow::{Context, Result, bail};
use plist::{Dictionary, Value};

use crate::config::{LABEL_PREFIX, ServiceConfig, Store, Workload};
use crate::runtime::run_checked;

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
    let file =
        fs::File::create(&path).with_context(|| format!("failed to create {}", path.display()))?;
    plist::to_writer_xml(file, &Value::Dictionary(job))
        .with_context(|| format!("failed to write {}", path.display()))?;
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
    let path = write_agent(store, service)?;
    let target = format!("{}/{}", domain(), label(&service.name));
    if Command::new("launchctl")
        .args(["print", &target])
        .output()
        .is_ok_and(|output| output.status.success())
    {
        return run_checked(
            Command::new("launchctl").args(["kickstart", "-k", &target]),
            "launchctl kickstart",
        );
    }
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
    )
}

pub fn is_running(name: &str) -> bool {
    let target = format!("{}/{}", domain(), label(name));
    Command::new("launchctl")
        .args(["print", &target])
        .output()
        .is_ok_and(|output| output.status.success())
}

pub fn delete(name: &str) -> Result<()> {
    if is_running(name) {
        stop(name)?;
    }
    let path = agent_path(name)?;
    if path.exists() {
        fs::remove_file(&path).with_context(|| format!("failed to remove {}", path.display()))?;
    }
    Ok(())
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
