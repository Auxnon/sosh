//! What survives a restart: the server's address and the session token, in
//! the user's config folder (`~/.config/sosh/session.json` on Linux), only
//! readable by them. `SOSH_CONFIG` points it elsewhere (for trying things
//! out).

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

pub const DEFAULT_SERVER: &str = "https://sosh.makeavoy.com";

#[derive(Serialize, Deserialize, Default, Clone)]
pub struct Saved {
    pub server: Option<String>,
    pub token: Option<String>,
}

fn dir() -> PathBuf {
    if let Some(d) = std::env::var_os("SOSH_CONFIG") {
        return PathBuf::from(d);
    }
    #[cfg(target_os = "macos")]
    let base = std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support"));
    #[cfg(target_os = "windows")]
    let base = std::env::var_os("APPDATA").map(PathBuf::from);
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let base = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")));
    base.unwrap_or_else(|| PathBuf::from(".")).join("sosh")
}

impl Saved {
    pub fn load() -> Saved {
        std::fs::read(dir().join("session.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self) {
        let d = dir();
        if std::fs::create_dir_all(&d).is_err() {
            return;
        }
        let path = d.join("session.json");
        let Ok(text) = serde_json::to_vec_pretty(self) else { return };
        let tmp = d.join("session.json.new");
        if std::fs::write(&tmp, text).is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
            }
            let _ = std::fs::rename(&tmp, &path);
        }
    }

    pub fn server_or_default(&self) -> String {
        self.server.clone().unwrap_or_else(|| DEFAULT_SERVER.to_owned())
    }
}
