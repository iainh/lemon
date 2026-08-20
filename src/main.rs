mod capacity;
mod cli;
mod config;
mod fsutil;
mod launchd;
mod network;
mod runtime;

use anyhow::Result;
use clap::Parser;

fn main() -> Result<()> {
    cli::Cli::parse().run()
}
