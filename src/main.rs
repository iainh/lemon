mod cli;
mod config;
mod launchd;
mod network;
mod runtime;

use anyhow::Result;
use clap::Parser;

fn main() -> Result<()> {
    cli::Cli::parse().run()
}
