use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize, de::DeserializeOwned};

use crate::fsutil::{atomic_write, clone_file};

pub const LABEL_PREFIX: &str = "dev.lemon";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VmConfig {
    pub name: String,
    pub cpus: u8,
    pub memory_mib: u32,
    #[serde(default)]
    pub mac_address: Option<String>,
    #[serde(default)]
    pub cloud_init: Option<CloudInitConfig>,
    pub boot: VmBoot,
    pub disks: Vec<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CloudInitConfig {
    pub user: String,
    pub user_data: PathBuf,
    pub meta_data: PathBuf,
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
        match (
            std::env::var_os("LEMON_CONFIG_DIR"),
            std::env::var_os("LEMON_DATA_DIR"),
        ) {
            (Some(config_dir), Some(data_dir)) => {
                return Ok(Self {
                    config_dir: config_dir.into(),
                    data_dir: data_dir.into(),
                });
            }
            (None, None) => {}
            _ => bail!("LEMON_CONFIG_DIR and LEMON_DATA_DIR must be set together"),
        }
        let directory = home_dir()?.join("Library/Application Support/dev.lemon.lemon");
        Ok(Self {
            config_dir: directory.clone(),
            data_dir: directory,
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

    pub fn service_log_paths(&self, service: &ServiceConfig) -> Vec<PathBuf> {
        let mut paths = vec![
            self.log_dir().join(format!("{}.log", service.name)),
            self.log_dir().join(format!("{}.error.log", service.name)),
        ];
        if let Workload::Vm { vm } = &service.workload {
            paths.push(self.log_dir().join(format!("vm-{vm}.log")));
        }
        paths
    }

    pub fn efi_store_path(&self, name: &str) -> PathBuf {
        self.vm_data_dir(name).join("efi-vars")
    }

    pub fn vm_lock_path(&self, name: &str) -> PathBuf {
        self.vm_data_dir(name).join("run.lock")
    }

    pub fn vm_data_dir(&self, name: &str) -> PathBuf {
        self.data_dir.join("vms").join(name)
    }

    pub fn create_cloud_init(
        &self,
        vm_name: &str,
        user: &str,
        public_key: &str,
    ) -> Result<CloudInitConfig> {
        let directory = self.data_dir.join("vms").join(vm_name).join("cloud-init");
        fs::create_dir_all(&directory)
            .with_context(|| format!("failed to create {}", directory.display()))?;
        let user_data = directory.join("user-data");
        let meta_data = directory.join("meta-data");
        atomic_write(
            &user_data,
            format!(
                "#cloud-config\nusers:\n  - name: {}\n    lock_passwd: true\n    shell: /bin/sh\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    ssh_authorized_keys:\n      - {}\nssh_pwauth: false\ndisable_root: true\n",
                yaml_string(user),
                yaml_string(public_key),
            )
            .as_bytes(),
        )
        .with_context(|| format!("failed to write {}", user_data.display()))?;
        atomic_write(
            &meta_data,
            format!(
                "instance-id: {}\nlocal-hostname: {}\n",
                yaml_string(&format!("lemon-{vm_name}")),
                yaml_string(vm_name),
            )
            .as_bytes(),
        )
        .with_context(|| format!("failed to write {}", meta_data.display()))?;
        Ok(CloudInitConfig {
            user: user.to_owned(),
            user_data,
            meta_data,
        })
    }

    pub fn save_vm(&self, config: &VmConfig) -> Result<()> {
        write_toml(&self.vm_path(&config.name), config)
    }

    pub fn clone_vm(&self, source: &VmConfig, name: &str) -> Result<VmConfig> {
        let directory = self.vm_data_dir(name);
        if directory.exists() {
            bail!("VM data directory already exists ({})", directory.display());
        }
        let result = (|| {
            let mut disks = Vec::with_capacity(source.disks.len());
            for (index, disk) in source.disks.iter().enumerate() {
                let filename = disk.file_name().context("VM disk path has no filename")?;
                let destination = directory
                    .join("disks")
                    .join(format!("{index}-{}", filename.to_string_lossy()));
                clone_file(disk, &destination)?;
                disks.push(destination);
            }
            let boot = match &source.boot {
                VmBoot::Linux {
                    kernel,
                    initrd,
                    cmdline,
                } => VmBoot::Linux {
                    kernel: kernel.clone(),
                    initrd: initrd.clone(),
                    cmdline: cmdline.clone(),
                },
                VmBoot::Efi { variable_store } => {
                    let destination = self.efi_store_path(name);
                    if variable_store.exists() {
                        clone_file(variable_store, &destination)?;
                    }
                    VmBoot::Efi {
                        variable_store: destination,
                    }
                }
            };
            let cloud_init = source
                .cloud_init
                .as_ref()
                .map(|cloud_init| -> Result<CloudInitConfig> {
                    let target = directory.join("cloud-init");
                    let user_data = target.join("user-data");
                    let meta_data = target.join("meta-data");
                    clone_file(&cloud_init.user_data, &user_data)?;
                    atomic_write(
                        &meta_data,
                        format!(
                            "instance-id: {}\nlocal-hostname: {}\n",
                            yaml_string(&format!("lemon-{name}")),
                            yaml_string(name),
                        )
                        .as_bytes(),
                    )?;
                    Ok(CloudInitConfig {
                        user: cloud_init.user.clone(),
                        user_data,
                        meta_data,
                    })
                })
                .transpose()?;
            Ok(VmConfig {
                name: name.into(),
                cpus: source.cpus,
                memory_mib: source.memory_mib,
                mac_address: Some(generate_mac_address()?),
                cloud_init,
                boot,
                disks,
            })
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(directory);
        }
        result
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

pub fn home_dir() -> Result<PathBuf> {
    let home = std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .context("HOME is not set")?;
    let home = PathBuf::from(home);
    if !home.is_absolute() {
        bail!("HOME must be an absolute path ({})", home.display());
    }
    Ok(home)
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

fn yaml_string(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn write_toml<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let body = toml::to_string_pretty(value).context("failed to serialize configuration")?;
    atomic_write(path, body.as_bytes())
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
    use std::os::unix::fs::PermissionsExt;

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
    fn creates_cloud_init_data_with_an_authorized_key() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store {
            config_dir: temp.path().join("config"),
            data_dir: temp.path().join("data"),
        };
        let config = store
            .create_cloud_init("dev", "lemon", "ssh-ed25519 AAAA'test key")
            .unwrap();
        let user_data = fs::read_to_string(config.user_data).unwrap();
        assert!(user_data.contains("name: 'lemon'"));
        assert!(user_data.contains("ssh-ed25519 AAAA''test key"));
        assert_eq!(config.user, "lemon");
        assert_eq!(
            fs::metadata(config.meta_data).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn clones_vm_storage_and_identity() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store {
            config_dir: temp.path().join("config"),
            data_dir: temp.path().join("data"),
        };
        let disk = temp.path().join("source.raw");
        fs::write(&disk, b"source disk").unwrap();
        let cloud_init = store
            .create_cloud_init("source", "lemon", "ssh-ed25519 AAAA")
            .unwrap();
        let source = VmConfig {
            name: "source".into(),
            cpus: 2,
            memory_mib: 2048,
            mac_address: Some("02:00:00:00:00:01".into()),
            cloud_init: Some(cloud_init),
            boot: VmBoot::Linux {
                kernel: "/kernel".into(),
                initrd: None,
                cmdline: "console=hvc0".into(),
            },
            disks: vec![disk],
        };

        let clone = store.clone_vm(&source, "clone").unwrap();

        assert_eq!(fs::read(&clone.disks[0]).unwrap(), b"source disk");
        assert_ne!(clone.mac_address, source.mac_address);
        let metadata = fs::read_to_string(clone.cloud_init.unwrap().meta_data).unwrap();
        assert!(metadata.contains("lemon-clone"));
        assert!(metadata.contains("local-hostname: 'clone'"));
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
