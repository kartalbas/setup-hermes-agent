# Credential files

Files the provisioner **deploys** onto the host, rather than creating there.

Everything in this directory is gitignored. It exists so that nothing has to be
produced by hand on the target after installation: what the service account
needs, it receives from here.

    ssh/       an SSH key pair for git. Generate it before the first run and add
               the public half to your forge; then the agent can push from the
               moment it starts, instead of being blocked until you notice.

    agy/       the CLI's OAuth token, copied out of an account you signed in
    claude/    with. Optional — without them the run installs the CLIs and tells
               you the one-line sign-in command instead.

Which file goes where is declared by CREDENTIAL_FILES in config/install.conf.
Modes are set on deployment; what they are here does not matter, but 0600 is
the sane habit.

## Generating the SSH key before you install

    ssh-keygen -t ed25519 -f config/credentials/ssh/id_ed25519 -N "" \
               -C "hermes@your-host"
    cat config/credentials/ssh/id_ed25519.pub     # add this to GitHub/GitLab

If you skip this, the run generates the key here anyway and prints the public
half — you just add it afterwards instead of before.
