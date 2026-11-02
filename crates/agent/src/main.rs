#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use std::net::Ipv4Addr;
use std::path::PathBuf;
use std::time::Duration;

#[tokio::main]
async fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let result = match arguments.as_slice() {
        [command, flag, path, mode]
            if command == "run" && flag == "--config" && mode == "--on-demand" =>
        {
            quirewire_agent::m6::run_agent(PathBuf::from(path), true).await
        }
        [command, flag, path] if command == "run" && flag == "--config" => {
            quirewire_agent::m6::run_agent(PathBuf::from(path), false).await
        }
        [command, address, port, flag, output]
            if command == "diagnose-lan" && flag == "--output" =>
        {
            diagnose_lan(address, port, output)
        }
        [command, address, port, flag, output]
            if command == "diagnose-scan" && flag == "--output" =>
        {
            diagnose_scan(address, port, output)
        }
        [command] if command == "help" || command == "--help" || command == "-h" => {
            println!(
                "QuireWire on-demand agent\nUsage:\n  quirewire-agent run --config <m6.conf> [--on-demand]\n  quirewire-agent diagnose-lan <IPv4> <port> --output <path>\n  quirewire-agent diagnose-scan <IPv4> <port> --output <path>"
            );
            Ok(())
        }
        _ => Err("Usage: quirewire-agent run --config <m6.conf> [--on-demand] | diagnose-lan <IPv4> <port> --output <path> | diagnose-scan <IPv4> <port> --output <path>".into()),
    };
    if let Err(error) = result {
        eprintln!("quirewire-agent: {error}");
        std::process::exit(1);
    }
}

fn diagnose_scan(
    address: &str,
    port: &str,
    output: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let address = address.parse::<Ipv4Addr>()?;
    let port = port.parse::<u16>()?;
    let result = quirewire_provider_lan::browse_live_scan_advertisement(
        "Brother via QuireWire Scanner",
        address,
        port,
        Duration::from_secs(15),
    );
    match result {
        Ok(detail) => {
            std::fs::write(output, format!("ok=true\n{detail}\n"))?;
            Ok(())
        }
        Err(error) => {
            std::fs::write(output, format!("ok=false\nerror={error}\n"))?;
            Err(error.into())
        }
    }
}

fn diagnose_lan(address: &str, port: &str, output: &str) -> Result<(), Box<dyn std::error::Error>> {
    let address = address.parse::<Ipv4Addr>()?;
    let port = port.parse::<u16>()?;
    let result = quirewire_provider_lan::browse_live_advertisement(
        "Brother via QuireWire",
        address,
        port,
        Duration::from_secs(15),
    );
    match result {
        Ok(detail) => {
            std::fs::write(output, format!("ok=true\n{detail}\n"))?;
            Ok(())
        }
        Err(error) => {
            std::fs::write(output, format!("ok=false\nerror={error}\n"))?;
            Err(error.into())
        }
    }
}
