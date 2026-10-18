# neosweep

**A disk cleaner for the terminal that tells the truth about how much space you get back.** It finds the caches, downloads, emulators
and big files on your Mac that you can delete, shows what deleting each one *really* frees (not what `du` or Finder adds up), lets you
choose, and deletes them. Full-screen, no app to sign or install, nothing else to download.

```
neosweep [--scan] [--list] [--detail id] [--top n] [--json] [--plain] [--leftovers file] [category ...]
```

On a terminal, with no options, it opens the full-screen view. The options only report; they delete nothing.

## The idea: sizes that are honest

Most cleaners add up the sizes of the files and promise you that much. On APFS that is often wrong: a *clone* (`cp -c`, a Chrome
update, an APFS snapshot) shares its blocks with another file, so deleting one gives back almost nothing. On the Mac this was written
on, 36 copies of Chrome in a hidden folder add up to **55 GB**; deleting all of them frees about **10 MB**, because the Chrome you
use holds the same blocks.

`neosweep` asks the file system for the **private size** of every file (`ATTR_CMNEXT_PRIVATESIZE`): the bytes that go away when
*this* file goes away. That is the number it calls **frees**, and it is a *lower bound*: when every member of a clone family is
deleted together it can be more, and a file with several hard links counts 0 until the last link is gone. After a deletion it also
measures what the volume really gained and tells you both numbers.

| column | meaning |
|---|---|
| `frees` | what deleting it gives back for certain (the private size) |
| `on disk` | what the files occupy, shared blocks included (what `du` prints) |

## The menus

**This Mac.** A view of the disk from the top, like `ncdu`: the folders of the whole disk with their sizes, biggest first. You go into a
folder only if you want to. Nothing is assumed: every folder is listed and can be opened, whether or not `neosweep` has heard of it. What can be deleted depends on where it is, not on its name: the home, other folders you own and connected disks can; the
Applications folder and Homebrew are handled by their menus (their rows are grey: they show their size but are not opened); the data of an installed
application in `Library/Application Support`, `Containers` and `Group Containers` is grey too, because it goes with the application; the system is only told about.
In the menu, Disk clean is the first entry and This Mac the last.

**Disk clean.** Known, regenerable data in categories. You choose which categories to look at (the ones that come back by themselves
are chosen already), watch them being added up (in parallel), open a category to see what is inside (which models make up
"Hugging Face: 23 GB", not just the total), and choose items. Everything is listed with what it is and how it comes back.

| kind | what it holds | selected at the start |
|---|---|---|
| **Trash** | what you already threw away (every mounted volume's Trash too) | yes |
| **cache** | comes back by itself: application caches, logs, Xcode build products, the Homebrew, npm, Yarn, pip and uv caches | yes (Apple's own `com.apple.*` caches are listed, not selected) |
| **download** | comes back after a download or a rebuild: pnpm store, Gradle, Dart and Flutter packages, Hugging Face and Whisper models, Puppeteer browsers, Xcode device support, old installers in Downloads (30 days and older) | no |
| **your data** | holds your own state, and does not come back: Android emulators, Node versions installed with nvm, iPhone and iPad backups (named by device and date), Xcode archives, Xcode simulators (removed with `xcrun simctl delete`), virtual machines | no, and named in red before you confirm |
| **developer tools** | three categories made from a table of tools, listed only for the tools that are on this Mac: **caches** (linters, build tools, test runners, terminal tools; chosen), **downloads** (Cargo, Go, Maven, PyTorch, Ollama, LM Studio, Conda packages...; not chosen) and **installed versions** (pyenv, rustup, Conda environments, the Android SDK, Colima...; not chosen, named in red). Logins, tokens, histories and settings (`~/.aws`, `~/.docker`, `~/.claude`...) are not in the table | caches only |
| **projects** | the folders of your projects that come back by one command: `node_modules` (next to a `package.json`), Python virtual environments (a folder with `pyvenv.cfg`), Rust `target` (next to `Cargo.toml`), `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache` (gathered by project) and `.git/lfs/objects`. Found by walking your home folder when you pick the row (it takes a while), shown with their whole path, `~/opt/xxx/node_modules`. A folder is found only when the file that proves it is next to it, and a deletion reaches only folders of these names. | no |
| **not sure whose** | what the careful leftover search leaves out and a person may still want to delete: another product of an installed application's maker, a name with an installed application's name in it, a name that is not an identifier (`Spotify`, `Adobe`), a file where an application keeps a folder. Each says why beside it. Never Apple's, never what an installed application owns. | not looked at, and nothing chosen, until you ask |
| **system** | `/Library/Updates`, system logs and caches: need administrator rights | only reported, never deleted |
| **report** | Docker's disk image: one file with everything inside; `neosweep` cannot look into it | only reported (run `docker system prune`) |

**Applications.** Every installed application with what it takes on disk, when it was last opened, and what it left in your Library
(caches, preferences, logs, saved state, containers...). Choosing an application chooses the application and everything it left, so that nothing is left behind: caches, preferences, logs, saved state,
Application Support, Containers and Group Containers, and the folders it keeps outside the Library (`~/.cache`, `~/.config`, `~/.local/share`, found only by its exact
identifier or name). What holds data is named in red in the confirmation. Applications that stand in folders of Applications (`Utilities/…`, `Unity/Hub/…`) are listed
with their folder. With the pane off (or on a narrow terminal) Enter on an application shows its parts, to choose one by one. What is still in your Library for applications that are not installed any more (you dragged them to the Trash and the data stayed) is not here but in
**Disk clean**, under "Left behind by something that was removed": it is not an uninstall, the application is already gone. Each application is one
item, chosen when it left only caches, logs, preferences or saved state, and not chosen when it left data. Only names that clearly are an
application's identifier are offered, and anything that might belong to an installed application, and everything of Apple's, is left out.
An application owned by an administrator (App Store, `.pkg` installs) needs your password: `neosweep` never asks for it; press `p` in the
result to ask Finder to move those to the Trash (Finder asks for your password and the space comes back when you empty the Trash).
The sizes of an application count what it occupies; the clones an application makes of itself (Chrome keeps 36 copies of itself) are
shown as what it occupies and not as what they free.

**Homebrew** (when it is installed). Read from Homebrew's own files, removed by `brew uninstall`, which knows what depends on what.
Sections: the packages you installed (with what needs them), libraries nothing needs any more (chosen: this is what `brew autoremove` does),
applications installed with `brew install --cask`, old versions next to the current one (chosen: `brew cleanup`), and and in Disk clean (under "Left behind by something that was removed"): the data
`brew uninstall` leaves behind on purpose (a database in `var`: listed, not chosen), and folders in `~/.config`, `Application Support` and Homebrew's `etc`
that carry the name of a package that is not installed (found by name in Homebrew's own index, never chosen: the name may belong to something else). A cask that needs your password fails with the
message of `brew`; run that command yourself.

**Large files.** The biggest files in your home folder, biggest first, with a size filter (`+` and `-`). Files that are not on this Mac
(iCloud files that are only in the cloud) take no space and are not listed. Left out on purpose: the Library (one file taken out of
an application's data can break the application), the Trash, packages (an application, a Photos library), `.git` folders, links and
hard-linked files. A file that changed between listing and deleting is left alone.

**iCloud.** What you see in iCloud Drive in Finder: Desktop and Documents (when they are synced), the folders and files of iCloud Drive, and the folder of
every application that keeps its documents there (Keynote, Numbers, Obsidian...), with the size in iCloud next to the size on this Mac. Enter opens a
folder (like a tree, one level at a time), ← goes back; Desktop and Documents can be opened but not chosen as a whole. What you choose in one folder stays
chosen when you go up. Deleting from here deletes from iCloud on every
device, and the confirmation says so. The total storage of your iCloud account cannot be read from the command line, so it is not shown.

**Sizes.** Shown as Finder counts them: decimal (1 GB is 1 000 000 000 bytes), always with two decimals so that every figure lines up on its separator, and the unit in
its own column. From 100 MB it is in GB (864 MB is 0,86 GB), from 1 MB in MB, below that in KB (125 bytes are 0,13 KB). A dash (—) means there is nothing to say (not readable, not applicable), never an invented 0. Rows are sorted by size while they are still being added up, and the
cursor stays on its row. The line with what you have chosen is at the top of every list, so it stays in view. The folders of the item under the cursor are listed under the table with what each takes.

**The pane on the right.** On a terminal of 120 columns or more the screen is two halves with a line between them: the list on the left, and on the right what
is in the row under the cursor, without going in (the items of a category, the folders of an item, the biggest entries of a folder of the disk or of iCloud), with
the same columns as the list. The headers of both are on the same row; what the row is stands at the bottom of the pane. A line under the title, a line under the
information at the top (what you are looking at and what you have chosen) and a line above the footer frame the screen on every terminal. `v` switches the pane off.
Large files has no pane, and a folder that has only files in it (nothing to look into) is a list of the whole width. In Applications an application is chosen whole
(Space: the application and everything it left) while the pane shows its parts; with the pane off, Enter opens the parts on a page of their own. Names that do not fit lose their middle (`/opt/…/Android Studio.app`), the sizes stand at the right edge of the list, and the row under the
cursor is a coloured bar. While rows are still being added up the cursor stays at the top, on whatever is biggest then; once you move it, it follows its row.

**System and hidden.** At the top of This Mac and of a disk, everything that is only reported (the system, hidden entries, other users) is one row, opened with Enter and
not added up until you open it.

**A connected disk.** It is under `/Volumes` in This Mac, with the same view. A Time Machine disk is shown but never deleted from: Time Machine manages it.

## Deleting

- The confirmation lists what goes with where it is (`~/.cache`, not just `.cache`).
- Trying it on a real Mac: with `NEO_TRASH=1` in the environment, what you choose is moved to the Trash instead of deleted for good, so a trial can be taken back (the Trash itself, and programs such as `brew uninstall`, are refused in this mode).
- It is **for good**: nothing goes to the Trash (so there is nothing to empty afterwards). To make that hard to do by accident, you
  have to **type a word** (`delete`, or `silelim` in Turkish), not just press Enter.
- The confirmation lists what goes, the total, anything that holds your own data (in red), and **applications that are running** and
  use the data (Tab asks them to quit).
- Only places that are allowed are ever offered, and every path is checked right before it is deleted: it has to lie under the folders of its
  place, on the same file system, never be the folder itself, never be the home, the Library or a standard folder (Documents...) as a whole, and be
  the same file or folder that was listed. A link is deleted as a link and never followed.
- A failure (permission, a file in use, a locked file) is shown with its reason and the rest goes on. Nothing is forced.
- `neosweep` **never asks for your password** and never uses `sudo`. Places that need administrator rights are only reported.
- The Trash needs *Full Disk Access* for your terminal. `neosweep` says so, opens the right page of System Settings when you press
  `p`, waits, and goes on as soon as it can read the Trash.

## Why a name is, or is not, taken for a leftover

`neosweep --leftovers report.md` writes a report (it never replaces a file that is there): what is offered under "Left behind by something that was removed", and every
name of your Library that is left out with the reason (it does not look like an identifier, Apple's, the same maker as an installed application, a part of its name is an
installed application's, a file where an application keeps a folder). It is for looking at what the careful search does not take.

## The cache of sizes

Adding up a big folder takes time, so what was added up is remembered for 15 minutes (the list of the biggest files too, in `large-v1.json`; a file that is gone or has changed is dropped from it when it is read), in `~/.cache/neosweep/sizes-v1.json` (or under `$XDG_CACHE_HOME`; readable by you
only). Going back to a page, or starting `neosweep` again soon after, shows the sizes at once; the page says how old they are (`sizes from 4 min ago`). `r` forgets
what the page shows and adds it up again. A deletion forgets the paths it touched and the folders above them. The cache only decides what is shown: every deletion
checks the real files, and the reports for scripts (`--scan`, `--json`) never use it. A damaged file is ignored, and the folder can be deleted at any time.

## Reports for scripts

```sh
neosweep --scan                  # the table: what each category frees
neosweep --scan --json | jq .    # the same as data
neosweep --list                  # the categories that exist on this Mac
neosweep --detail huggingface    # the items of one category, biggest first
neosweep --json npm pip uv       # only these categories
```

Exit status 0, or 64 for a usage error. `--plain`, `NEOSWEEP_PLAIN=1`, `CI` and `TERM=dumb` turn the full-screen view off.

## Keys

| key | does |
|---|---|
| `↑ ↓`, `j k`, `PgUp PgDn`, `Home End` | move |
| `Enter`, `→` | open (a row that is still being added up is not opened: it would move under the cursor) |
| `Space` | choose |
| `a` | choose all (what is safe: an application and what is safe to take with it) |
| `A` | choose everything, what holds your data too (it is named in red before you confirm) |
| `n` | choose none |
| `v` | the pane on the right on or off |
| `o` | in Applications: open the parts of the application, to choose them one by one
| `r` | add the page up again (forget the cache of what it shows) |
| `d` | delete what is chosen (asks first) |
| `+` `-` | the size filter of Large files |
| `p` | allow access to what could not be read (the Trash, backups) |
| `f` | show the row under the cursor in Finder |
| `p` | in the result: ask Finder to move the applications that need a password |
| `Tab` | in the confirmation: ask the running applications to quit |
| `Esc`, `←` | back |
| `q`, `Ctrl-C` | quit (a deletion that is running finishes the item it is on) |

## Limits worth knowing

- Tested on one machine (Apple silicon, macOS 26). The size of an item is read when the scan finishes; files that change after that
  are not counted again.
- APFS local snapshots keep blocks alive: deleting a file that a snapshot still holds frees nothing until the snapshot goes
  (`neodf` shows the snapshots).
- The first time `neosweep` looks into Documents, Desktop or iCloud Drive, macOS may ask whether your terminal may.
- Only what ships with macOS is used; no other program reads the numbers.
