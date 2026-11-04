# Loopback TLS fixtures

These certificates and the leaf private key are public, test-only fixtures for
`NativeArtifact.HTTPContractTest`. The CA is trusted only through a request-local
`cacertfile`; no system trust configuration is changed. The leaf certificate is
issued for `localhost`, has server-auth usage, and expires in October 2036.

The fixtures were generated with OpenSSL using a separate CA certificate and a
CA-signed RSA leaf. The CA signing key was discarded. TLS peer and hostname
verification stay enabled in the integration test.
