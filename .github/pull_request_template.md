## What and why

<!-- What does this change, and what problem does it solve? Link the issue if there is one. -->

## How it was checked

<!-- The command you ran, the suite you ran (`swift test --filter <Suite>`), a comparison with the original command. For a fix: the test that fails without it. -->

## Checklist

- [ ] Behaves like the original command when piped (same text, same exit code), unless a flag asks otherwise
- [ ] Text for people is in the String Catalog and the help files, not in Swift code ([CONTRIBUTING](https://github.com/reachdevel/neotools/blob/main/CONTRIBUTING.md))
- [ ] No `!`, `try!`, `fatalError` or `as!` on anything that depends on the system or the input
- [ ] Tests added or updated; `swift test` passes
- [ ] Docs updated (`docs/commands/`, README) and a line added to [CHANGELOG.md](https://github.com/reachdevel/neotools/blob/main/CHANGELOG.md) if users will notice
