use std::time::Duration;

use printbridge_domain::{ComponentState, GuestPrinting, PrinterEndpoint};
use printbridge_provider_cups::CupsIppProvider;

fn main() {
    if let Err(error) = run() {
        eprintln!("M4 CUPS probe failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args().skip(1);
    let port = arguments
        .next()
        .ok_or("usage: m4_probe <loopback-port> <queue>")?
        .parse::<u16>()?;
    let queue = arguments
        .next()
        .ok_or("usage: m4_probe <loopback-port> <queue>")?;
    if arguments.next().is_some() {
        return Err("usage: m4_probe <loopback-port> <queue>".into());
    }
    let endpoint = PrinterEndpoint::Loopback {
        port,
        queue: queue.clone(),
    };
    let provider = CupsIppProvider::new(endpoint.clone(), Duration::from_secs(10));
    provider.probe_ipp(&endpoint)?;
    let queues = provider.list_queues()?;
    if queues.len() != 1 || queues[0].name != queue {
        return Err("CUPS did not advertise the expected queue name".into());
    }
    println!("ipp=pass");
    println!("queue={queue}");
    for entry in provider.diagnostics()? {
        println!("{}={}", entry.name, entry.value);
    }
    let advertisement = provider.advertisement()?;
    println!("make_model={}", advertisement.make_model);
    println!("formats={}", advertisement.formats.join(","));
    println!("urf={}", advertisement.urf.join(","));
    println!("color={}", advertisement.color);
    println!("duplex={}", advertisement.duplex);
    let status = provider.queue_status(&queue)?;
    if status.state != ComponentState::Ready {
        return Err(format!("CUPS queue is not ready: {status:?}").into());
    }
    println!("state={}", status.state.as_str());
    Ok(())
}
