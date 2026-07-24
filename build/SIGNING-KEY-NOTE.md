# Update signing key
`sparkle_ed25519_key.pem` signs in-app updates (Sparkle EdDSA). It lives in
this PRIVATE repo because the repo's token cannot create Actions secrets.
If the repo ever goes public, move the key to a GitHub Actions secret named
SPARKLE_PRIVATE_KEY and delete the file from history first.
