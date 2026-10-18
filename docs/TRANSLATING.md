# Translating neotools

Everything the neotools commands say to a person (the `--help` of each command, the notes, the summaries, the table headers,
the descriptions of processes) can be shown in your language. English and Turkish ship today. A new language needs **no
Swift**: you edit two kinds of text files and run the tests.

You can translate part of it: whatever is missing falls back to English, key by key. A partial translation is welcome, and you can
finish it later.

## What is translated and what is not

Translate what a person reads. Do **not** translate what a program reads:

| translate | never translate |
|---|---|
| `--help` texts, notes and hints, summaries ("3 files moved to the Trash"), the headers and words of our own tables (`neotop`, `neonet`, `neodf`), names of roles and groups, descriptions of processes | command names (`neodu`), options and flags (`--plain`, `-r`), environment variables, JSON keys, file names, application names |
| | messages that imitate an original command (`du`'s errors, `df`'s columns, `find`'s messages): they are English on purpose so that scripts keep working, and they are not in the catalog |

Application names are the ones macOS shows (the code asks the system), so "Clock" is not yours to translate.

## Where the text lives

Both live in `Sources/NeoCore/Resources/`:

1. **`Localizable.xcstrings`**: one String Catalog with every short message (about 800 keys). Open it in Xcode (it has a catalog
   editor) or edit the JSON in any editor. Keys look like `net.hidden`, `top.derivedNote`, `docs.error.zipTooBig`. The
   `proc.*` keys (about 190) are the descriptions of macOS processes that `neotop --describe` shows.
2. **`<language>.lproj/help-<command>.txt`**: one plain text file per command, for example `tr.lproj/help-du.txt`. Copy the
   English file and translate it. There are 15 files: `df docs du find free lsof media net ps setup sweep top top-keys trash tree`.

The language code is the usual one: `fr`, `de`, `es`, `pt`, `pt_BR`, `ja`, `zh_Hans`... A code with a region (`pt_BR`) is tried
first, then the language alone (`pt`), then English.

## Step by step

1. **Get the code and build it** (see [CONTRIBUTING.md](../CONTRIBUTING.md)):

   ```sh
   git clone https://github.com/reachdevel/neotools.git && cd neotools
   swift build
   ```

2. **Add the help files.** Copy the English folder and translate each file:

   ```sh
   cp -R Sources/NeoCore/Resources/en.lproj Sources/NeoCore/Resources/fr.lproj
   ```

   Keep the structure: a title line, the usage line, the options one per line in groups, a few examples. Rules for these files:

   - Keep the tokens as they are: `{program}` (the name the command was started as), `{PROGRAM}` (the same in capitals), and a line that
     starts with `{indent}` (it is aligned under the usage text above it).
   - Keep options, flags and example commands exactly as in English. Translate the descriptions.
   - Keep the columns: the descriptions start in the same column as in English (about column 18), and no line is wider than 80
     characters where English is not. If a translation does not fit on one line, continue it on the next line, indented under the
     description.
   - Names of macOS places and features use the words of macOS in your language (see below).

3. **Add the messages.** In `Localizable.xcstrings`, each entry looks like this:

   ```json
   "net.cannotReadSockets": {
     "localizations": {
       "en": { "stringUnit": { "state": "translated", "value": "%1$@: cannot read the socket list: %2$@" } },
       "tr": { "stringUnit": { "state": "translated", "value": "%1$@: soket listesi okunamıyor: %2$@" } }
     }
   }
   ```

   Add a block for your language next to `en` and `tr` in every entry you translate.

   - **Placeholders** (`%@`, `%lld`, `%1$@`, `%2$lld`, `%%` for a percent sign) must be the same ones, with the same numbers, as in
     English. Their order may change in your language (that is what the `%1$` and `%2$` are for). A test checks this.
   - **Plurals** use the `variations` form. English has `one` and `other`:

     ```json
     "df.snapshots": { "localizations": { "en": { "variations": { "plural": {
         "one":   { "stringUnit": { "state": "translated", "value": "1 local snapshot" } },
         "other": { "stringUnit": { "state": "translated", "value": "%lld local snapshots" } } } } } } }
     ```

     Give your language every plural form it needs (`zero`, `one`, `two`, `few`, `many`, `other`). A language with one form (Turkish,
     Japanese, Chinese) gives a plain `stringUnit` and needs no `variations`.
   - Do not add an ASCII version. A terminal that is not UTF-8 gets one by automatic transliteration (`ığşöüç` becomes `igsouc`).

4. **Try it.** The language is chosen by `NEO_LANG`, then `LC_ALL`, `LC_MESSAGES`, `LANG`:

   ```sh
   swift build
   NEO_LANG=fr .build/debug/neodu --help
   NEO_LANG=fr .build/debug/neotop --once --top 3
   NEO_LANG=fr .build/debug/neodf
   ```

   Look at every help, and at the messages you can provoke (a missing file, a wrong option).

5. **Run the checks:**

   ```sh
   swift test --filter Localization
   ```

   They check that the placeholders of every language match English (an extra language may be partial: missing keys fall back to
   English and are not failures), that the lookup falls back to English (`fr_CA` -> `fr` -> `en`), and, for English and Turkish, that
   every command has a help file with only the known tokens and an aligned usage block. For your own help files, check by eye
   that `{program}`, `{PROGRAM}` and `{indent}` are the only `{...}` words, and that no `{` is left in the output of
   `NEO_LANG=<code> .build/debug/<command> --help`.

To list what is still missing in your language:

```sh
python3 - <<'EOF'
import json, sys
lang = "fr"
d = json.load(open("Sources/NeoCore/Resources/Localizable.xcstrings"))["strings"]
missing = [k for k, v in d.items() if lang not in v.get("localizations", {})]
print(len(missing), "of", len(d), "keys have no", lang, "text")
print("\n".join(sorted(missing)))
EOF
```

## How to translate

Translate for a reader, not word for word. A good translation reads as if it had been written in your language.

- **Use the vocabulary of macOS in your language**: its menus, System Settings, the Apple glossary. A product is called what
  Apple calls it in that language (in Turkish "Find My" is "Bul", "Voice Memos" is "Sesli Notlar", "Migration Assistant" is
  "Taşıma Asistanı"). Check how Finder, Activity Monitor and System Settings word the same idea on a Mac set to your language.
- The descriptions of processes (`proc.<name>`) say what a macOS process is for, in one short line, in the same words Activity
  Monitor or Apple's documentation would use.
- Keep sentences short, and match the tone of the English: plain, technical, no jokes.
- Units and numbers are not yours to localize: `GiB`, `ms` and the decimal separator come from the system.
- Never translate the English into another language's English words: if a term has no good translation, keep the English term.
- If the English text is wrong or unclear, say so in your pull request instead of translating the mistake.

## How to get your translation into the project

Pick the way that is easiest for you:

1. **Pull request (preferred).** Fork the repository, make a branch (`translation-fr`), commit the `fr.lproj/` folder and the
   changes to `Localizable.xcstrings`, and open a pull request titled "Translation: French". Say whether it is complete or partial
   and who reviewed it.
2. **Issue with files.** If you do not use git, open an issue titled "Translation: French" and attach the translated
   `help-*.txt` files and the part of the catalog you translated (a copy of `Localizable.xcstrings` is fine).
3. **Email.** Send the same files to reachdevel@gmail.com with "neotools translation" in the subject.

You will be credited in the release notes unless you prefer not. A maintainer runs the checks, reads the translation next to the
English for placeholders and layout, and asks you about anything unclear. If a native reader other than the translator can
review it, the merge is faster; say so in the pull request.

## Keeping a translation up to date

When a command gains a message, the English text and the keys are added first, and your language falls back to English until it
is translated. Run the "what is missing" snippet above now and then, or watch the pull requests that change `Localizable.xcstrings`
and `en.lproj`. If you stop maintaining a language, say so: an unmaintained translation is better than none, and it can be
adopted by someone else.

## For developers adding a message

Never write a user-visible string in a runner. Add the key to the catalog and the help file in English (and in every language you
can), ask `Messages` for it in the code, and add it to the list of machine-facing text only if it imitates an original command. See
[CONTRIBUTING.md](../CONTRIBUTING.md).
