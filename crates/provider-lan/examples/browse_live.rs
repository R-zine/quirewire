use std::net::Ipv4Addr;
use std::time::Duration;

use printbridge_provider_lan::browse_live_advertisement;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args().skip(1);
    let expected_instance = arguments
        .next()
        .unwrap_or_else(|| "Brother via PrintBridge".into());
    let expected_address = arguments
        .next()
        .unwrap_or_else(|| "192.168.100.72".into())
        .parse::<Ipv4Addr>()?;
    let expected_port = arguments
        .next()
        .unwrap_or_else(|| "8644".into())
        .parse::<u16>()?;
    if arguments.next().is_some() {
        return Err("usage: browse_live [INSTANCE] [IPV4] [PORT]".into());
    }

    println!(
        "{}",
        browse_live_advertisement(
            &expected_instance,
            expected_address,
            expected_port,
            Duration::from_secs(15),
        )?
    );
    Ok(())
}
