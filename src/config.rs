use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize, de::DeserializeOwned};

pub const LABEL_PREFIX: &str = "dev.lemon";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VmConfig {
    pub name: String,
    pub cpus: u8,
    pub memory_mib: u32,
    #[serde(default)]
    pub mac_address: Option<String>,
    pub boot: VmBoot,
    pub disks: Vec<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum VmBoot {
    Linux {
        kernel: PathBuf,
        initrd: Option<PathBuf>,
        cmdline: String,
    },
    Efi {
        variable_store: PathBuf,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ServiceConfig {
    pub name: String,
    pub restart: bool,
    #[serde(flatten)]
    pub workload: Workload,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum Workload {
    Vm {
        vm: String,
    },
    Container {
        image: String,
        cpus: Option<u8>,
        memory: Option<String>,
        env: Vec<String>,
        publish: Vec<String>,
        volumes: Vec<String>,
        command: Vec<String>,
    },
}

#[derive(Debug, Clone)]
pub struct Store {
    pub config_dir: PathBuf,
    pub data_dir: PathBuf,
}

impl Store {
    pub fn discover() -> Result<Self> {
        let dirs = ProjectDirs::from("dev", "lemon", "lemon")
            .context("could not determine the current user's home directory")?;
        Ok(Self {
            config_dir: dirs.config_dir().to_path_buf(),
            data_dir: dirs.data_dir().to_path_buf(),
        })
    }

    pub fn vm_path(&self, name: &str) -> PathBuf {
        self.config_dir.join("vms").join(format!("{name}.toml"))
    }

    pub fn service_path(&self, name: &str) -> PathBuf {
        self.config_dir
            .join("services")
            .join(format!("{name}.toml"))
    }

    pub fn log_dir(&self) -> PathBuf {
        self.data_dir.join("logs")
    }

    pub fn efi_store_path(&self, name: &str) -> PathBuf {
        self.data_dir.join("vms").join(name).join("efi-vars")
    }

    pub fn save_vm(&self, config: &VmConfig) -> Result<()> {
        write_toml(&self.vm_path(&config.name), config)
    }

    pub fn load_vm(&self, name: &str) -> Result<VmConfig> {
        let mut config: VmConfig = read_toml(&self.vm_path(name), "VM", name)?;
        if config.mac_address.is_none() {
            config.mac_address = Some(generate_mac_address()?);
            self.save_vm(&config)?;
        }
        Ok(config)
    }

    pub fn save_service(&self, config: &ServiceConfig) -> Result<()> {
        write_toml(&self.service_path(&config.name), config)
    }

    pub fn load_service(&self, name: &str) -> Result<ServiceConfig> {
        read_toml(&self.service_path(name), "service", name)
    }

    pub fn list_vms(&self) -> Result<Vec<VmConfig>> {
        read_dir_toml(&self.config_dir.join("vms"))
    }

    pub fn list_services(&self) -> Result<Vec<ServiceConfig>> {
        read_dir_toml(&self.config_dir.join("services"))
    }
}

pub fn validate_name(name: &str) -> Result<()> {
    let mut chars = name.chars();
    let first = chars.next();
    if !matches!(first, Some(c) if c.is_ascii_alphanumeric())
        || !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        bail!(
            "invalid name {name:?}; use letters, numbers, '.', '_' or '-', starting with a letter or number"
        );
    }
    Ok(())
}

pub fn generate_mac_address() -> Result<String> {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("failed to generate a VM MAC address: {error}"))?;
    bytes[0] = (bytes[0] | 0x02) & 0xfe;
    Ok(bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<Vec<_>>()
        .join(":"))
}

fn write_toml<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let parent = path.parent().context("configuration path has no parent")?;
    fs::create_dir_all(parent).with_context(|| format!("failed to create {}", parent.display()))?;
    let body = toml::to_string_pretty(value).context("failed to serialize configuration")?;
    fs::write(path, body).with_context(|| format!("failed to write {}", path.display()))
}

fn read_toml<T: DeserializeOwned>(path: &Path, kind: &str, name: &str) -> Result<T> {
    let body = fs::read_to_string(path)
        .with_context(|| format!("{kind} {name:?} does not exist ({})", path.display()))?;
    toml::from_str(&body).with_context(|| format!("failed to parse {}", path.display()))
}

fn read_dir_toml<T: DeserializeOwned>(dir: &Path) -> Result<Vec<T>> {
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut paths = fs::read_dir(dir)
        .with_context(|| format!("failed to read {}", dir.display()))?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<std::io::Result<Vec<_>>>()?;
    paths.sort();
    paths
        .into_iter()
        .filter(|path| path.extension().is_some_and(|ext| ext == "toml"))
        .map(|path| read_toml(&path, "configuration", &path.display().to_string()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_names() {
        assert!(validate_name("web-1.prod").is_ok());
        assert!(validate_name("").is_err());
        assert!(validate_name("bad/name").is_err());
        assert!(validate_name("_bad").is_err());
    }

    #[test]
    fn generates_a_locally_administered_unicast_mac_address() {
        let mac = generate_mac_address().unwrap();
        let first = u8::from_str_radix(&mac[..2], 16).unwrap();
        assert_eq!(mac.len(), 17);
        assert_eq!(first & 0x03, 0x02);
    }

    #[test]
    fn round_trips_a_service() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store {
            config_dir: temp.path().join("config"),
            data_dir: temp.path().join("data"),
        };
        let service = ServiceConfig {
            name: "web".into(),
            restart: true,
            workload: Workload::Container {
                image: "nginx:latest".into(),
                cpus: Some(2),
                memory: Some("1G".into()),
                env: vec!["MODE=production".into()],
                publish: vec!["8080:80".into()],
                volumes: vec![],
                command: vec![],
            },
        };
        store.save_service(&service).unwrap();
        assert_eq!(store.load_service("web").unwrap(), service);
    }
}
