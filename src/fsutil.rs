#[cfg(target_os = "macos")]
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Write;
#[cfg(target_os = "macos")]
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use anyhow::{Context, Result};

pub fn atomic_write(path: &Path, contents: &[u8]) -> Result<()> {
    let parent = path.parent().context("file path has no parent")?;
    fs::create_dir_all(parent).with_context(|| format!("failed to create {}", parent.display()))?;

    let mut suffix = [0_u8; 8];
    getrandom::fill(&mut suffix)
        .map_err(|error| anyhow::anyhow!("failed to create temporary filename: {error}"))?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name().unwrap_or_default().to_string_lossy(),
        u64::from_ne_bytes(suffix)
    ));

    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
            .with_context(|| format!("failed to create {}", temporary.display()))?;
        file.write_all(contents)
            .with_context(|| format!("failed to write {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("failed to sync {}", temporary.display()))?;
        fs::rename(&temporary, path)
            .with_context(|| format!("failed to replace {}", path.display()))?;
        FileSync::sync(parent)
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub fn clone_file(source: &Path, destination: &Path) -> Result<()> {
    let parent = destination.parent().context("clone path has no parent")?;
    fs::create_dir_all(parent).with_context(|| format!("failed to create {}", parent.display()))?;
    clone_file_native(source, destination).with_context(|| {
        format!(
            "failed to clone {} to {}",
            source.display(),
            destination.display()
        )
    })
}

#[cfg(target_os = "macos")]
fn clone_file_native(source: &Path, destination: &Path) -> std::io::Result<()> {
    let source_path = CString::new(source.as_os_str().as_bytes())
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?;
    let destination_path = CString::new(destination.as_os_str().as_bytes())
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?;
    // SAFETY: both pointers are valid, NUL-terminated path strings for the duration of the call.
    if unsafe { libc::clonefile(source_path.as_ptr(), destination_path.as_ptr(), 0) } == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if !matches!(
        error.raw_os_error(),
        Some(libc::ENOTSUP) | Some(libc::EXDEV)
    ) {
        return Err(error);
    }
    fs::copy(source, destination).map(|_| ())
}

#[cfg(not(target_os = "macos"))]
fn clone_file_native(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::copy(source, destination).map(|_| ())
}

struct FileSync;

impl FileSync {
    fn sync(path: &Path) -> Result<()> {
        fs::File::open(path)
            .and_then(|directory| directory.sync_all())
            .with_context(|| format!("failed to sync {}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn atomically_replaces_a_private_file() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("nested/config.toml");

        atomic_write(&path, b"first").unwrap();
        atomic_write(&path, b"second").unwrap();

        assert_eq!(fs::read(&path).unwrap(), b"second");
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn clones_a_file() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.raw");
        let destination = temp.path().join("nested/destination.raw");
        fs::write(&source, b"disk contents").unwrap();

        clone_file(&source, &destination).unwrap();

        assert_eq!(fs::read(destination).unwrap(), b"disk contents");
    }
}
