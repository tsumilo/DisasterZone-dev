#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Msg(String),
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("network: {0}")]
    Net(String),
}

pub type Result<T> = std::result::Result<T, Error>;
