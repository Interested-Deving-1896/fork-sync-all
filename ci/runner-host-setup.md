# bdfs privileged runner host setup

This document covers setting up a self-hosted Incus runner for the
`btrfs-dwarfs-framework` integration-test stage. The runner needs
privileged containers so CI jobs can use `losetup`, BTRFS mounts, and FUSE.

## Prerequisites

On the runner host:

```bash
# Incus
apt-get install -y incus
incus admin init --minimal

# gitlab-runner
curl -fsSL https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | bash
apt-get install -y gitlab-runner

# BTRFS + FUSE tools (needed inside containers, but also on the host for loopback)
apt-get install -y btrfs-progs fuse3 fuse-overlayfs util-linux

# Add gitlab-runner user to incus-admin group
usermod -aG incus-admin gitlab-runner
```

## Incus profile for bdfs integration tests

The standard `gitlab-runner` profile uses `security.privileged: false`.
bdfs integration tests require a privileged profile with `/dev` pass-through
so `losetup` and BTRFS mounts work inside the container.

Apply the bdfs-specific profile:

```bash
incus profile create bdfs-privileged < ci/incus-profile-bdfs.yaml
```

The profile file is at `ci/incus-profile-bdfs.yaml` in this repository.

## Install executor scripts

Clone this repository on the runner host, then:

```bash
# Initialise the gitlab-enhanced submodule (provides the executor scripts)
git submodule update --init integrations/gitlab-enhanced

# Install executor scripts
sudo bash integrations/gitlab-enhanced/runtime/incus/runner/install.sh

# Apply the gitlab-enhanced base runner profile (networking, cloud-init)
incus profile create gitlab-runner \
  < integrations/gitlab-enhanced/runtime/incus/profiles/gitlab-runner.yaml

# Apply the bdfs privileged profile
incus profile create bdfs-privileged < ci/incus-profile-bdfs.yaml
```

## Runner registration

1. Go to **GitLab → btrfs-dwarfs-framework → Settings → CI/CD → Runners →
   New project runner**
2. Set tags: `privileged, self-hosted, incus`
3. Uncheck "Run untagged jobs"
4. Copy the token (`glrt-...`)

Store as masked CI/CD variables:

| Variable | Value |
|---|---|
| `BDFS_RUNNER_TOKEN` | Token from step 4 |
| `BDFS_RUNNER_HOST` | `user@hostname` of the runner host |
| `BDFS_RUNNER_SSH_KEY` | Private key PEM for SSH access |

Then trigger the **`register-runner`** job manually from the pipeline UI
(it appears in the `build` stage, `when: manual`).

Alternatively, register directly on the runner host:

```bash
sudo gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.com" \
  --token "glrt-YOUR_TOKEN" \
  --executor custom \
  --builds-dir /builds \
  --cache-dir /cache \
  --custom-config-exec  /usr/local/lib/gitlab-runner-incus/config.sh \
  --custom-prepare-exec /usr/local/lib/gitlab-runner-incus/prepare.sh \
  --custom-run-exec     /usr/local/lib/gitlab-runner-incus/run.sh \
  --custom-cleanup-exec /usr/local/lib/gitlab-runner-incus/cleanup.sh \
  --tag-list "privileged,self-hosted,incus" \
  --run-untagged false \
  --locked false \
  --description "bdfs-integration-privileged"

sudo gitlab-runner start
```

## Verify

```bash
sudo gitlab-runner list
# Should show: bdfs-integration-privileged   Executor=custom  Token=...  URL=https://gitlab.com

incus profile list
# Should show: bdfs-privileged, gitlab-runner
```

Once the runner is online, the `integration:workspace-health-check` and
`integration:ipfs-pin` jobs will route to it automatically on the next pipeline.

## Troubleshooting

**`losetup` fails inside container**

Verify the `bdfs-privileged` profile is applied and `security.privileged: true`
is set. Check with:

```bash
incus config show ci-job-<JOB_ID> | grep security
```

**BTRFS mount fails with `EPERM`**

The container needs `CAP_SYS_ADMIN`. This is granted by `security.privileged: true`.
If using unprivileged containers, add `linux.kernel_modules: btrfs` and
`security.syscalls.intercept.mknod: true` to the profile instead.

**Container not cleaned up after failed job**

```bash
incus list | grep ci-job-
incus delete --force ci-job-<JOB_ID>
```
