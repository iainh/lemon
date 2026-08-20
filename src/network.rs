use std::fs;
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

const DHCP_LEASES: &str = "/var/db/dhcpd_leases";

pub fn wait_for_ssh(mac_address: &str, timeout: Duration) -> Result<IpAddr> {
    let deadline = Instant::now() + timeout;
    let mut leased_address = None;
    loop {
        if let Some(address) = find_dhcp_lease(Path::new(DHCP_LEASES), mac_address)? {
            leased_address = Some(address);
            let socket = SocketAddr::new(address, 22);
            if TcpStream::connect_timeout(&socket, Duration::from_millis(500)).is_ok() {
                return Ok(address);
            }
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

fn find_dhcp_lease(path: &Path, mac_address: &str) -> Result<Option<IpAddr>> {
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
    let mut matching_address = None;

    for line in body.lines().map(str::trim) {
        match line {
            "{" => {
                address = None;
                hardware_address = None;
            }
            "}" => {
                if hardware_address == Some(expected_mac) {
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
                    _ => {}
                }
            }
        }
    }
    Ok(matching_address)
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
            "{\nip_address=192.168.64.2\nhw_address=1,a:b:c:d:e:f\n}\n\
             {\nname=dev\nip_address=192.168.64.3\nhw_address=1,0a:0b:0c:0d:0e:0f\nlease=123\n}\n",
        )
        .unwrap();
        assert_eq!(
            find_dhcp_lease(&path, "0a:0b:0c:0d:0e:0f").unwrap(),
            Some("192.168.64.3".parse().unwrap())
        );
    }
}
