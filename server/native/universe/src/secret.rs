//! Passwords: Argon2id hashes in PHC string form (`$argon2id$v=19$...`),
//! salt included. Hashing is deliberately slow (about 20ms and 19 MiB), so
//! the NIFs run on the dirty CPU schedulers and never stall the BEAM's.

use argon2::password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, SaltString};
use argon2::{Algorithm, Argon2, Params, PasswordVerifier, Version};

/// OWASP's minimum for Argon2id: 19 MiB, 2 passes, 1 lane.
fn argon() -> Argon2<'static> {
    let params = Params::new(19 * 1024, 2, 1, None).expect("argon2 params");
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
}

pub fn hash(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    argon()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

/// False for a wrong password or a hash that doesn't parse. The hash's own
/// parameters are used, so older hashes keep verifying if `argon` changes.
pub fn verify(password: &str, hash: &str) -> bool {
    match PasswordHash::new(hash) {
        Ok(h) => argon().verify_password(password.as_bytes(), &h).is_ok(),
        Err(_) => false,
    }
}

/// Spend the same time as a real check, for an account that doesn't exist,
/// so response times don't tell which emails have accounts.
pub fn waste_time(password: &str) {
    let _ = hash(password);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_verify_and_differ() {
        let a = hash("correct horse").unwrap();
        let b = hash("correct horse").unwrap();
        assert!(a.starts_with("$argon2id$"));
        assert_ne!(a, b, "salted");
        assert!(verify("correct horse", &a));
        assert!(!verify("battery staple", &a));
        assert!(!verify("correct horse", "not a hash"));
    }
}
