use anyhow::Result;
use clap::Parser;
use tracing::info;

use touchcore::config::{Cli, Config};
use touchcore::selftest;
use touchcore::socks5;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .with_target(false)
        .init();

    let cli = Cli::parse();
    if cli.self_test {
        let cfg = Config::from_cli(cli)?;
        return selftest::run(cfg).await;
    }

    let cfg = Config::from_cli(cli)?;
    if cfg.has_tamper() {
        info!("touchcore {}", cfg.summary());
    }
    socks5::serve(cfg).await.map_err(Into::into)
}
