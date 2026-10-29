use std::path::PathBuf;

#[tokio::main]
async fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let result = match arguments.as_slice() {
        [command, flag, path] if command == "run" && flag == "--config" => {
            printbridge_agent::m6::run_agent(PathBuf::from(path)).await
        }
        [command] if command == "help" || command == "--help" || command == "-h" => {
            println!(
                "PrintBridge M6 headless agent\nUsage: printbridge-agent run --config <m6.conf>"
            );
            Ok(())
        }
        _ => Err("Usage: printbridge-agent run --config <m6.conf>".into()),
    };
    if let Err(error) = result {
        eprintln!("printbridge-agent: {error}");
        std::process::exit(1);
    }
}
