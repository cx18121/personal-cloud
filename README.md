# Personal cloud

This repository provisions and configures my private remote development host.

## Boundaries

- AWS owns compute, encrypted block storage, snapshots, and the break-glass Systems Manager path.
- Tailscale owns private network access.
- mise owns repeatable host tools, repositories, and portable Pi configuration.
- Herdr owns terminal-first sessions.
- Emdash owns the visual task, worktree, review, and automation experience.
- Pi with CXStack owns agent execution policy.

The AWS provider refuses to run outside the dedicated `personal-cloud` account in `us-east-1`. Local account values live in the ignored `mise.local.toml` file. Terraform state is local and ignored.

## Infrastructure

The Terraform configuration creates:

- One `m7i.xlarge` Ubuntu 24.04 instance.
- A VPC and public subnet with no inbound security-group rules.
- A 30 GiB encrypted root volume.
- A separate 300 GiB encrypted volume mounted at `/home` and protected from Terraform deletion.
- Fourteen daily EBS snapshots of the home volume.
- An instance role limited to Systems Manager core access.
- A gross monthly budget with alerts at $200, forecasted $250, and actual $300.

The public IPv4 address provides outbound internet access without a NAT Gateway. SSH is reachable only through Tailscale after enrollment.

## Provision

```bash
mise trust
mise run init
mise run plan
mise run apply
```

Use the Terraform output to open the first Systems Manager session. Enroll the host into the personal Tailscale account:

```bash
sudo tailscale up --ssh --hostname personal-cloud
```

After the Mac is connected to the same tailnet, bootstrap the developer environment:

```bash
./scripts/bootstrap-remote.sh
```

The remote bootstrap is an AWS-host adapter. It verifies the persistent `/home` volume, installs host prerequisites, updates the durable `~/dotfiles` checkout, and delegates the complete Linux developer environment to that repository's locked mise bootstrap. It then applies only personal-cloud safeguards and Emdash service setup.

Shared tools, repositories, dotfiles, Pi settings, Herdr, and agent skills are owned by `cx18121/dotfiles` and their app repositories. Credentials, provider logins, sessions, memory, caches, run history, and trust decisions are not copied.

## Emdash

Install Emdash on the Mac and add `personal-cloud` as a remote SSH machine. Emdash installs and owns the remote workspace server version.

After the first successful Emdash connection, run the bootstrap again. It detects the workspace server and configures automatic startup after reboot:

```bash
./scripts/bootstrap-remote.sh
```

Keep Emdash tmux disabled on this host. The workspace server already owns persistent remote terminals, and Emdash 1.2.3 launches its tmux wrapper through `/bin/sh` in a way that breaks Pi's Bash command line. Use Herdr when you need direct terminal multiplexing.

## Recovery

Files under `/home` survive ordinary instance replacement on the protected EBS volume.

If the volume itself is lost, choose a DLM snapshot and set `TF_VAR_home_snapshot_id` before Terraform creates its replacement. The snapshot must be in the same region, and `data_volume_size` must be at least as large as the snapshot.

`prevent_destroy` protects the volume, so setting `TF_VAR_home_snapshot_id` while a healthy volume is still tracked fails the plan instead of replacing it. That is deliberate. Remove the lost volume from state first:

```bash
mise exec -- terraform -chdir=infra state rm aws_ebs_volume.home
```

The same protection turns an Availability Zone change into a plan error rather than silent data loss.

After the replacement is attached, rerun the bootstrap. Root-volume state does not survive, so Tailscale and other machine-level authentication may need to be repeated. Running processes do not survive an EC2 reboot.

The host still boots when the home volume is missing, so it stays reachable for repair. It does not silently accept work in that state. The bootstrap refuses to run, the Emdash service refuses to start, and interactive shells print a warning.
