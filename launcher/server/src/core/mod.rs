//! (the names the bot's modules had inside the launcher: crate::core::bridge, crate::core::Result)

pub mod error;
pub use crate::bridge;
pub use error::{Error, Result};
