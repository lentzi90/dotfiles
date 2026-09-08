# dotfiles

Simply dotfiles

```bash
# Dry run
DRY_RUN=true ./setup.sh
# Specify persona to use
PERSONA=work ./setup.sh
PERSONA=private ./setup.sh
```

`setup.sh` remembers the persona you used (in `~/.config/dotfiles/persona`).
Once it has run at least once, you can pull the latest changes and re-apply
the setup with the same persona using the `dotfiles_update` shell function
(from `functions/dotfiles.sh`, sourced via `.bash_aliases`):

```bash
dotfiles_update
```

`dotfiles_update` refuses to touch anything if the repo has uncommitted
changes, and only pulls if it can fast-forward cleanly (`git pull --ff-only`),
so it will never leave the repo in a conflicted state.
