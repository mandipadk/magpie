# Deploying the Magpie hub

The hub runs on Frankfurt: `/opt/magpie` (releases, owned by ubuntu), `/var/lib/magpie`
(the hub's data, owned by magpie), units `magpie-hub` and `magpie-hubd`.

## For pipelines and duties

    sudo -n /usr/local/sbin/magpie-deploy
    sudo -n -u magpie /opt/magpie/current/magpie-hubd status --home /var/lib/magpie

`magpie-deploy` takes no arguments. As ubuntu it builds, tests and stages HEAD of
`~/code/magpie` (`magpie/deploy.sh --stage`); as root it switches `/opt/magpie/current`,
restarts the two units, waits up to a minute for the hub to be healthy (status, port 22000,
`magpie-firewall check`) and rolls back if not. It ends with the hub's status. Nothing from
the repo runs as root.

`magpie/deploy.sh --build-only` needs no privilege at all; run it as ubuntu.

## What needs privilege

Only these steps of `deploy.sh`; build, test, installing a release and the symlinks don't:

| step | runs as |
| --- | --- |
| `systemctl restart magpie-hub`, `systemctl restart magpie-hubd` (deploy and rollback) | root |
| `/usr/local/sbin/magpie-firewall check` (health check) | root |
| `/opt/magpie/current/magpie-hubd status --home /var/lib/magpie` (health check) | magpie |

## Installed files

- `/usr/local/sbin/magpie-deploy`: root:root 0755, a copy of `magpie-deploy` here.
- `/etc/sudoers.d/magpie-deploy`: root:root 0440, a copy of `sudoers-deploy` here. Allows
  ubuntu the wrapper with no arguments, and the status command with exactly those arguments.

`install.sh` installs both. To install or update just these two by hand:

    sudo visudo -cf magpie/deploy/sudoers-deploy
    sudo install -o root -g root -m 0755 magpie/deploy/magpie-deploy /usr/local/sbin/magpie-deploy
    sudo install -o root -g root -m 0440 magpie/deploy/sudoers-deploy /etc/sudoers.d/magpie-deploy
    sudo visudo -c

The older `/etc/sudoers.d/magpie` (from `sudoers` here) is separate and unchanged; `deploy.sh`
with no arguments still uses it.

## Rollback

    sudo rm /etc/sudoers.d/magpie-deploy /usr/local/sbin/magpie-deploy
    sudo visudo -c

That's all: deploys go back to `deploy.sh` with no arguments, exactly as before. That path is
already password-free for sudo under `/etc/sudoers.d/magpie`.

## Why this exists when sudo already allows it

At the server level `/etc/sudoers.d/magpie-deploy` adds nothing: `/etc/sudoers.d/magpie`
already lets ubuntu run every privileged step of `deploy.sh` without a password, and ubuntu
also has `NOPASSWD: ALL` on Frankfurt. sudo never asked for approval. What stopped the daily
duty was the agent session's safety check, which refuses a repo script that calls sudo, so
each deploy went to the owner through `power run`. The wrapper gives that check one fixed,
root-owned command to allow:

    ssh frankfurt 'sudo -n /usr/local/sbin/magpie-deploy'

Unattended deploys need that command (and the status command) in the agents' allow rules;
the sudoers file alone doesn't do it.
