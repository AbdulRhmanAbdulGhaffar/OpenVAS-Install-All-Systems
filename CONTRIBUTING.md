# Contributing

Thanks for considering contributing! Please:

1. Discuss big changes in an issue first.
2. Run CI locally when possible:
   - `shellcheck -x openvas-install.sh`
   - `yamllint .`
3. Keep PRs focused and small.
4. For new flags, update `README.md` and `--help`.
5. Test at least one distro per family (Debian/Ubuntu, RHEL/Rocky/Alma, Arch if applicable).
