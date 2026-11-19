# Security updates in base images

The Ubuntu security pocket uses Canonical's signed repository directly.
General release and update packages retain the configured mirror list. This
keeps security fixes available when an ordinary mirror has not synchronized
the security pocket yet. A failed index download stops the image build.

Run the build contract check with:

```sh
bash exordos/images/exordos_base/tests/test-security-sources.sh
```

Rebuilding a base image does not update existing nodes or images already
derived from it. Release a new image version, rebuild the affected Core,
load-balancer, Workspace and Realm images, and verify their installed package
revisions on an isolated stand before moving the production `latest` alias.

For CVE-2026-123007, Ubuntu's fixed nginx revisions start at
`1.24.0-2ubuntu7.20` on 24.04 and `1.28.3-2ubuntu1.13` on 26.04. The short
`nginx -v` output does not include the Ubuntu patch revision. Check the full
installed package revision with `dpkg-query`, validate with `nginx -t`, and
check that every running nginx process executes the installed binary. A
reload can leave the old master executable resident; restart the owning
service after updating the package.

Reference: <https://ubuntu.com/security/CVE-2026-123007>.
