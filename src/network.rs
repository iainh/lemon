use std::fs;
use std::io::Read;
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};

const DHCP_LEASES: &str = "/var/db/dhcpd_leases";

pub fn wait_for_ssh(mac_address: &str, timeout: Duration) -> Result<IpAddr> {
    let deadline = Instant::now() + timeout;
    let mut leased_address = None;
    loop {
        if let Some(address) = ssh_address(mac_address)? {
            return Ok(address);
        }
        if let Some(address) = find_dhcp_lease(Path::new(DHCP_LEASES), mac_address)? {
            leased_address = Some(address);
        }
        if Instant::now() >= deadline {
            break;
        }
        thread::sleep(Duration::from_millis(500));
    }
    if let Some(address) = leased_address {
        bail!("VM has DHCP address {address}, but SSH did not become ready within {timeout:?}");
    }
    bail!("VM did not obtain a DHCP lease within {timeout:?}");
}

pub fn ssh_address(mac_address: &str) -> Result<Option<IpAddr>> {
    let Some(address) = find_dhcp_lease(Path::new(DHCP_LEASES), mac_address)? else {
        return Ok(None);
    };
    let socket = SocketAddr::new(address, 22);
    let Ok(mut stream) = TcpStream::connect_timeout(&socket, Duration::from_millis(500)) else {
        return Ok(None);
    };
    stream.set_read_timeout(Some(Duration::from_millis(500)))?;
    let mut banner = [0_u8; 255];
    let Ok(length) = stream.read(&mut banner) else {
        return Ok(None);
    };
    Ok(has_ssh_banner(&banner[..length]).then_some(address))
}

fn has_ssh_banner(bytes: &[u8]) -> bool {
    bytes
        .split(|byte| *byte == b'\n')
        .any(|line| line.starts_with(b"SSH-"))
}

fn find_dhcp_lease(path: &Path, mac_address: &str) -> Result<Option<IpAddr>> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before the Unix epoch")?
        .as_secs();
    find_dhcp_lease_at(path, mac_address, now)
}

fn find_dhcp_lease_at(path: &Path, mac_address: &str, now: u64) -> Result<Option<IpAddr>> {
    let expected_mac = parse_mac(mac_address)?;
    let body = match fs::read_to_string(path) {
        Ok(body) => body,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| {
                format!("failed to read macOS DHCP leases from {}", path.display())
            });
        }
    };
    let mut address = None;
    let mut hardware_address = None;
    let mut expires_at = None;
    let mut matching_address = None;

    for line in body.lines().map(str::trim) {
        match line {
            "{" => {
                address = None;
                hardware_address = None;
                expires_at = None;
            }
            "}" => {
                if hardware_address == Some(expected_mac)
                    && expires_at.is_some_and(|lease| lease > now)
                {
                    if let Some(address) = address {
                        matching_address = Some(address);
                    }
                }
            }
            _ => {
                let Some((key, value)) = line.split_once('=') else {
                    continue;
                };
                match key {
                    "ip_address" => address = value.parse().ok(),
                    "hw_address" => {
                        let value = value.split_once(',').map_or(value, |(_, value)| value);
                        hardware_address = parse_mac(value).ok();
                    }
                    "lease" => expires_at = parse_lease(value),
                    _ => {}
                }
            }
        }
    }
    Ok(matching_address)
}

fn parse_lease(value: &str) -> Option<u64> {
    value.strip_prefix("0x").map_or_else(
        || value.parse().ok(),
        |value| u64::from_str_radix(value, 16).ok(),
    )
}

fn parse_mac(value: &str) -> Result<[u8; 6]> {
    let octets = value
        .split(':')
        .map(|octet| u8::from_str_radix(octet, 16))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    octets
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid MAC address {value:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_last_matching_dhcp_lease() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("leases");
        fs::write(
            &path,
            "{\nip_address=192.168.64.2\nhw_address=1,0a:0b:0c:0d:0e:0f\nlease=0x96\n}\n\
             {\nname=dev\nip_address=192.168.64.3\nhw_address=1,0a:0b:0c:0d:0e:0f\nlease=0xc8\n}\n",
        )
        .unwrap();
        assert_eq!(
            find_dhcp_lease_at(&path, "0a:0b:0c:0d:0e:0f", 100).unwrap(),
            Some("192.168.64.3".parse().unwrap())
        );
        assert_eq!(
            find_dhcp_lease_at(&path, "0a:0b:0c:0d:0e:0f", 200).unwrap(),
            None
        );
    }

    #[test]
    fn recognizes_an_ssh_identification_banner() {
        assert!(has_ssh_banner(b"SSH-2.0-OpenSSH_10.0\r\n"));
        assert!(has_ssh_banner(b"notice\r\nSSH-2.0-OpenSSH_10.0\r\n"));
        assert!(!has_ssh_banner(b"HTTP/1.1 200 OK\r\n"));
    }
}
