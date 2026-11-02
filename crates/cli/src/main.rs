fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let code = quirewirectl::run(&arguments, &mut std::io::stdout(), &mut std::io::stderr());
    std::process::exit(code);
}
