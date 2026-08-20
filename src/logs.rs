use std::fs;
use std::path::Path;

use anyhow::{Context, Result};

use crate::config::{ServiceConfig, Store};

const DEFAULT_MAX_BYTES: u64 = 10 * 1024 * 1024;
const RETAINED_FILES: usize = 3;

pub fn rotate_service(store: &Store, service: &ServiceConfig) -> Result<()> {
    let max_bytes: u64 =
        std::env::var("LEMON_LOG_MAX_BYTES").map_or(Ok(DEFAULT_MAX_BYTES), |value| {
            value
                .parse()
                .context("LEMON_LOG_MAX_BYTES must be a positive integer")
        })?;
    if max_bytes == 0 {
        anyhow::bail!("LEMON_LOG_MAX_BYTES must be a positive integer");
    }
    for path in store.service_log_paths(service) {
        rotate(&path, max_bytes, RETAINED_FILES)?;
    }
    Ok(())
}

pub fn purge_service(store: &Store, service: &ServiceConfig) -> Result<()> {
    for path in store.service_log_paths(service) {
        remove_if_present(&path)?;
        for index in 1..=RETAINED_FILES {
            remove_if_present(&rotated_path(&path, index))?;
        }
    }
    Ok(())
}

fn rotate(path: &Path, max_bytes: u64, retained_files: usize) -> Result<()> {
    let metadata = match path.metadata() {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to inspect {}", path.display()));
        }
    };
    if metadata.len() < max_bytes {
        return Ok(());
    }
    remove_if_present(&rotated_path(path, retained_files))?;
    for index in (1..retained_files).rev() {
        let source = rotated_path(path, index);
        if source.exists() {
            fs::rename(&source, rotated_path(path, index + 1))
                .with_context(|| format!("failed to rotate {}", source.display()))?;
        }
    }
    fs::rename(path, rotated_path(path, 1))
        .with_context(|| format!("failed to rotate {}", path.display()))
}

fn rotated_path(path: &Path, index: usize) -> std::path::PathBuf {
    path.with_file_name(format!(
        "{}.{}",
        path.file_name().unwrap_or_default().to_string_lossy(),
        index
    ))
}

fn remove_if_present(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("failed to remove {}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotates_logs_to_a_bounded_history() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("service.log");
        for contents in [b"one".as_slice(), b"two", b"three", b"four"] {
            fs::write(&path, contents).unwrap();
            rotate(&path, 1, 3).unwrap();
        }
        assert_eq!(fs::read(rotated_path(&path, 1)).unwrap(), b"four");
        assert_eq!(fs::read(rotated_path(&path, 2)).unwrap(), b"three");
        assert_eq!(fs::read(rotated_path(&path, 3)).unwrap(), b"two");
        assert!(!rotated_path(&path, 4).exists());
    }
}
