
Best Practices for Key Management

Since OIDC signers regularly update, it is highly recommended that you configure your client applications to dynamically pull public signing keys from Dex’s /.well-known/openid-configuration or /[issuer]/keys endpoints. This allows client systems to automatically adapt to any key rotations without manual intervention or service interruptions.If you'd like, let me know:What backend storage you are using (e.g., etcd, Postgres, Kubernetes)

The issue prompting you to want to disable key rotationI can help you troubleshoot the root cause or adjust your storage configurations.

