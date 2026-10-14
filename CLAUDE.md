# neotools: instructions for AI assistants

**neotools** is a family of macOS-native, Swift replacements for classic Unix commands. Read these first:

1. `README.md`: what the project is and is not, the commands, how they behave.
2. `CONTRIBUTING.md`: build, test, module layout, the rules the code follows, how to add a command or a language.
3. `docs/commands/<command>.md`: the behaviour of each command, what it copies from the original and what it adds.
4. `ROADMAP.md` and `TODO.md`: where the project is going and what is open. `CHANGELOG.md`: add a line for a change users will notice. `docs/TRANSLATING.md`: how text is translated.

## Principles

- **Behave like the original.** A neo tool is the classic command plus macOS-specific improvements. When behaviour is unclear, run `/usr/bin/<cmd>` and copy it, quirks included. Tests compare output, stderr and exit code with the real command.
- **Compare like with like.** Never compare an iCloud-aware tool with an unaware one (`du` against `neodu --local`). State the setup (warm or cold cache, tree, runs) with every number. No "faster than X" without a measurement that follows these rules.
- **Script-safe.** Decorations (spinners, live tables, colours, notes) only when stdout is a terminal. Piped output is byte-compatible with the original unless a flag asks otherwise.
- **Metadata only.** Never open or read a user's file unless the command is about its content (reading an evicted iCloud file downloads it).
- **Errors are handled, not assumed away.** No `!`, `try!`, `fatalError`, `as!` on anything that depends on the system or the input; write `guard let`. A failing system call is an error message and a status like the original's, never a crash or a wait. Sizes and counts from a file are checked before they size a buffer or a loop, and their arithmetic is overflow-safe. Handing a job to the original returns 127 (not found) / 126 (cannot run) like a shell (`execOriginal`). `RobustnessTests` runs every command with strange arguments, an empty environment, a full output and no `argv`; add a case when a bug of this kind is found, and test a failing path by running it.
- **Temporary files** are registered with `Cleanup` before they exist and removed in a `defer`; results are written to a hidden file and moved into place without replacing anything (`placeWithoutReplacing`).
- **Text for people lives in the String Catalog** (`Sources/NeoCore/Resources/Localizable.xcstrings`) and the `.lproj` help files, never in a runner. Machine-facing text (piped columns, JSON keys, messages that imitate the original) is English and not translated. See CONTRIBUTING.
- **`--help` is a help, not a README.** A title line, the usage line (do not explain defaults there), the options one per line grouped by purpose, a few examples. The left column stays narrow (about 18 characters); a pair of names that does not fit goes on two lines. A command with verbs has a section per verb. No design notes, no explanation of how the tool works inside, no mention of locale or `NEO_LANG`, no policy sentences. Model it on the shortest existing help (`neotrash`, `neodf`) and on `man`.
- **Only what ships with macOS** (system frameworks, `/usr/bin` tools) plus the vendored C libraries listed in `THIRD_PARTY_NOTICES.md`. Anything that may be missing degrades to "not shown". Another program is not used to read numbers; handing the whole job to the original (`find`, `rm`, `lsof`, `ps`) is fine.
- **Keep it simple.** Prefer the small change; discuss a large one first.

## Working rules

- During development run only the suites of the command you work on (`swift test --filter <Suite>`), plus the localization suite when the catalog or a help file changed. Run the whole suite when shared code changed and before you hand the work over. Do not call a task done without proof that it works: run it, and for a fix add the test that fails without it.
- A new command follows the checklist in CONTRIBUTING (contract first, text and help in every shipped language, errors, dependencies, tests, docs).
- Do not install, publish or push anything, and do not create tags, without explicit confirmation.
- Do not touch the user's real dotfiles or home from tests; scratch homes only. Never empty the Trash.
- Review claims before you act on them: Swift imports CoreFoundation `Create`/`Copy` functions as managed (ARC releases them), `takeRetainedValue()` hands the +1 to ARC, a `defer` runs on `return`. Check a "leak" or "missing check" against the header and the code a few lines away, and try a hostile input before you call something a bug.

## Facts worth knowing

- The iCloud flag is `SF_DATALESS` (0x40000000, `<sys/stat.h>`).
- `getattrlistbulk` plus several directories at a time is the fast path of the file commands.
- Apple's own `du.c`, `df.c` and `rm.c` are in https://github.com/apple-oss-distributions/file_cmds (APSL/BSD): read them to confirm behaviour, write our own code.
- Measurements were taken on a MacBook Air M1 (4P+4E), macOS 26, APFS, Swift 6. Other machines and macOS versions are untested.
