# Contributing to neotools

Thank you for wanting to help. neotools is a family of macOS-native Swift commands; it stays small and careful on purpose. This
page tells how to build it, how it is organised, the rules the code follows, and how to add a command, a fix or a language.

Open tasks are in [TODO.md](TODO.md) and the direction is in [ROADMAP.md](ROADMAP.md). For a security problem, see
[SECURITY.md](SECURITY.md) and do not open a public issue. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Build and test

You need macOS 14 or newer and the Swift 6 toolchain (Xcode 16+, or a Swift 6 toolchain from swift.org).

```sh
swift build                 # debug build of every command
swift build -c release      # the build the benchmarks use
swift test                  # the whole suite, a few minutes
swift test --filter DuTests # one suite: use this while you work on one command
```

- Run only the suites of the command you change (`--filter`), and the whole suite before you send a change.
- The tests run the real commands (`/usr/bin/du`, `/bin/df`, ...) next to the neo commands and compare stdout, stderr and the exit
  status. A test that needs the neo binary finds it in the build products; `NEO_BIN_DIR` points it elsewhere.
- Some tests depend on the machine: they create files in your Trash (with a unique name, they are yours to empty), start a pseudo
  terminal, run a busy child to measure power, or look at your volumes. The tests that open Pages, Numbers and Keynote run only with
  `NEODOCS_TEST_APPS=1`.
- Tests never touch your real dotfiles: `neo-setup` tests run in a scratch home.
- If a test is flaky on your Mac, please say so in the issue; timing-sensitive tests are a known weak spot.

## How the code is organised

One SwiftPM package, one executable per command (not a multi-call binary), a few library modules, and small vendored C libraries.

| module | what is in it |
|---|---|
| `NeoCore` | what every command needs: the terminal and the live table, text and units, the bulk directory scanner, `Messages` (the translations), and the smaller commands (`neodu`, `neodf`, `neofree`, `neotrash`, `neolsof`, `neofind`, `neotree`, `neops`, `neo-setup`) |
| `MediaKit` | `neomedia`: ImageIO, AVFoundation, the Matroska reader, the embedded codecs |
| `DocsKit` | `neodocs`: PDFKit, Vision, AppKit text, the PDF structure reader, spreadsheets, Parquet |
| `SweepKit` | `neosweep`: the categories, the scanner (private sizes), the full-screen view, and the one door every deletion goes through |
| `TopKit`, `NetKit`, `MicKit` | `neotop` (IOKit, IOReport), `neonet` (SystemConfiguration), the microphone query of `neolsof` |
| `CShim` | small C helpers for APIs Swift cannot reach directly |
| `CWebP`, `CVPX`, `CDAV1D`, `CVORBIS`, `CFLAC`, `CCARQUET` | vendored C libraries (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)); do not edit them, except through the wrapper files |
| `Sources/<command>/main.swift` | the same few lines for every command |
| `Tests/NeoTests` | all tests (Swift Testing) |

The heavy frameworks sit in their own modules so that `neodu` does not load AVFoundation, Vision, PDFKit and AppKit just to start.

## Rules the code follows

These come from the way the project is meant to behave. A change that breaks one will be asked to change.

1. **Behave like the original.** A neo command is the classic command plus macOS improvements. When behaviour is unclear, run
   `/usr/bin/<cmd>` and copy it, quirks included. Tests compare output, stderr and exit code with the real command.
2. **Compare like with like.** Never compare an iCloud-aware tool with an unaware one. State the setup (warm or cold cache, tree,
   number of runs) with every performance figure, and do not claim "faster than X" without a measurement that follows these rules.
3. **Script-safe.** Decorations (spinners, live tables, colours, notes) appear only when stdout is a terminal. Piped output is
   byte-compatible with the original unless a flag asks otherwise.
4. **Metadata only.** Never open or read a user's file unless the command is about its content; reading an evicted iCloud file
   downloads it.
5. **Errors are handled, not assumed away.** No `!`, `try!`, `fatalError`, `as!` on anything that depends on the system or the
   input (a lookup that "cannot fail" is written with `guard let`). A system call that fails is an error message and an exit
   status like the original's, never a crash or a wait. Sizes and counts that come from a file are checked before they size a
   buffer or a loop; arithmetic on them is overflow-safe. Handing a job to the original returns 127 (not found) / 126 (cannot run)
   like a shell. Add a case to `RobustnessTests` when you find a bug of this kind; a failing path is tested by running it.
6. **Only what ships with macOS.** System frameworks and `/usr/bin` tools, plus the vendored libraries. Anything that may be
   missing (a battery, a GPU, a private library) degrades to "not shown", never to a crash or a wrong number. Another program is not
   used to read numbers.
7. **A temporary file is registered with `Cleanup` before it exists**, and removed in a `defer`; results are written to a hidden
   file and moved into place without replacing anything (`placeWithoutReplacing`).
8. **Text for people lives in the catalog.** See below.
9. **`--help` is a help, not a README.** A title line, the usage line, the options one per line grouped by purpose (left column
   about 18 characters, a pair of names that does not fit goes on two lines), a few examples. No design notes, no explanation of how
   the tool works inside.
10. **Keep it simple.** Prefer the small change. Discuss a large one in an issue first.

A test is a reproduction: when you fix a bug, add the test that fails without the fix (a hostile file, a strange argument, a full
output, an empty environment).

## Adding or changing text, and adding a language

Translators: the step-by-step guide is [docs/TRANSLATING.md](docs/TRANSLATING.md), including how to send a translation. What follows is
the short version for developers.

Everything a person reads (help, notes, summaries, table headers) is in the **String Catalog**
`Sources/NeoCore/Resources/Localizable.xcstrings` and the help files `Sources/NeoCore/Resources/<lang>.lproj/help-<command>.txt`.
Never write a user-visible string in a runner: the code asks `Messages`, and `Messages` asks the catalog.

- Keys are symbolic (`<command>.<name>`); values use format specifiers (`%lld`, `%@`, `%%`) and plural variations.
- **Machine-facing text stays English and untranslated:** piped columns, JSON keys and enumerations, and messages that imitate an
  original (`du`'s errors, `df`'s columns, the Linux-style `free` table).
- Application names are the ones macOS shows (`FileManager.displayName`); we never translate a name ourselves.
- Add English and the other shipped language together when you add a message.

To add a language: add it in `Localizable.xcstrings` (Xcode's editor opens it, or edit the JSON), copy `en.lproj/` to
`<code>.lproj/` and translate the `help-*.txt` files keeping the tokens (`{program}`, `{PROGRAM}`, `{indent}`) and the structure.
Run `swift test`: the localization checks say what is missing. A language may be partial (missing keys fall back to English).
A translation should read as if it had been written in that language, and use the vocabulary of macOS in it (its menus, System
Settings, the Apple glossary). You do not provide an ASCII version: a terminal that is not UTF-8 gets one by transliteration.
`NEO_LANG` selects the language, then `LC_ALL`, `LC_MESSAGES`, `LANG`.

## Adding a new command

1. **Write the contract first** (in the pull request or an issue): what the original does (probe `/usr/bin/<cmd>`), what you add,
   what is machine-facing text, what it never changes.
2. **Text and help** in the catalog and `.lproj` files, in the languages that ship, from the start.
3. **Errors:** the rules above. `Sources/<cmd>/main.swift` is the same few lines as the others (and safe with no `argv`); add the
   command to the list in `RobustnessTests`, and run a pass with strange arguments, an empty environment and a full output.
4. **Dependencies:** only what ships with macOS, or a vendored library with a licence that allows it (add it to
   `THIRD_PARTY_NOTICES.md` with its `COPYING`).
5. **Tests:** differential against the original where there is one.
6. **Docs:** a page in `docs/commands/`, a row in the README table and in [ROADMAP.md](ROADMAP.md) if it was a planned item.

## Pull requests

- One topic per pull request, with the tests.
- Say what you tried and on which macOS version and chip.
- Performance changes come with the before and after numbers and the setup (see rule 2).
- Commit messages say what changed and why, in the imperative.
- A change that users will notice gets a line in [CHANGELOG.md](CHANGELOG.md) under "Unreleased".
- By contributing you agree that your work is under the [MIT licence](LICENSE).
