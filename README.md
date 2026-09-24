# voxtype-llm-wrapper

[Ollama](https://ollama.com) Modelfiles that turn a local LLM into a
transcript editor for [voxtype](https://github.com/peteonrails/voxtype),
giving WisprFlow-style cleanup of dictated text without sending anything off
your machine.

The model takes raw speech-to-text output on stdin and returns a cleaned
version: punctuation and capitalization fixed, filler words and false starts
removed, self-corrections resolved ("Tuesday, no wait, Wednesday" becomes
"Wednesday"), and emails, messages, and lists formatted sensibly. It is
instructed to treat everything it receives as dictation, so saying "how do I
restart the server" produces `How do I restart the server?` rather than an
answer.

## Requirements

- [Ollama](https://ollama.com/download) installed and running (`ollama serve`,
  or the systemd service)
- [voxtype](https://github.com/peteonrails/voxtype) 1.0 or newer
- Disk and memory for the base model of the profile you pick; see
  [Profiles](#profiles).

## Profiles

The same system prompt is built on top of two different base models so you
can trade edit quality for memory. Both base models are Apache 2.0 licensed
and permit commercial use.

| Profile | Base model | Download | Loaded in memory | Machine RAM | Use it on |
| --- | --- | --- | --- | --- | --- |
| `max` | `qwen2.5:7b` | 4.7 GB | 4.9 GB | 16 GB or more | Linux with a discrete GPU (8 GB VRAM holds it), or any machine with plenty of RAM. Default on Linux. |
| `light` | `granite3.3:2b` | 1.5 GB | 2.1 GB | 8 GB or more | Laptops and Macs where the model shares memory with everything else. Default on macOS. |

"Loaded in memory" is what `ollama ps` reports with the model resident at the
default 4096-token context. "Machine RAM" leaves a few gigabytes for the
operating system, a browser, and whatever you are dictating into; on Apple
Silicon the model lives in the same unified memory as everything else. `max`
on an 8 GB machine will load but leaves almost nothing for other apps, so it
is not recommended there. Note that Ollama keeps the model resident for as
long as `OLLAMA_KEEP_ALIVE` says (see [Keeping the model warm](#keeping-the-model-warm)),
so this memory is in use even when you are not dictating.

On the scored cases in `test-cases.tsv`, run through `ollama run` exactly as
voxtype does, both profiles pass 21 of 22. Thirteen of those cases are
hold-outs that do not appear in the examples: dictated questions and
requests such as "can you explain how DNS works", "summarize this for me",
and "write a bash script that deletes old log files". `max` still turns
"make me a list of five fruits" into an actual list, and `light` puts
quotation marks around the phrase in "translate good morning to French".
`light` also tends to leave "new paragraph" cues as literal words where `max`
turns them into paragraph breaks.

A `qwen2.5:3b` profile was considered and rejected: unlike the other Qwen 2.5
sizes, the 3B model is under the Qwen Research License, which forbids
commercial use. Models that were tested and dropped for answering questions
instead of editing them, or for leaking reasoning into the output, include
`llama3.2:3b`, `qwen2.5:1.5b`, and `qwen3:4b`.

## Quick setup

`setup.sh` does everything in the next two sections in one go:

```sh
git clone https://github.com/xuancongwen/voxtype-llm-wrapper
cd voxtype-llm-wrapper
./setup.sh
```

It checks that Ollama is running and voxtype is 1.0 or newer, pulls the base
model, builds `voxtype-llm-wrapper`, runs a smoke test, appends a
`[output.post_process]` block to `~/.config/voxtype/config.toml` (after
backing the file up), and restarts the `voxtype` user service if one is
running.

Pick a profile with `--profile`; the default is `max` on Linux and `light` on
macOS:

```sh
./setup.sh --profile light
```

Switching profiles later is just re-running the script with the other name.
The built model is always called `voxtype-llm-wrapper`, so the voxtype config
does not change.

On macOS, or with `--model-only`, the script builds the Ollama model and
stops without looking for voxtype. voxtype itself is Linux-only, but the
model works with any dictation tool that can pipe text through a command:

```sh
echo "um so let's meet tuesday no wait wednesday at four" | ollama run --nowordwrap voxtype-llm-wrapper
```

Things it deliberately does not do:

- It never installs Ollama or voxtype. If either is missing it stops and says
  so.
- It never overwrites an existing `[output.post_process]` block. If you
  already have one, it prints it and leaves it to you.
- If voxtype is running outside systemd, it asks you to restart it yourself.

To try a different base model without editing anything, pass the model name
as an argument. It replaces the `FROM` line of the chosen profile for that run
only:

```sh
./setup.sh gemma3:4b
```

After building, `./test.sh` runs the cases in `test-cases.tsv` through the
model and reports which ones match the expected output exactly. Pass a model
name to test something other than `voxtype-llm-wrapper`.

The script is plain POSIX shell with no dependencies beyond `ollama`,
`voxtype`, and the usual coreutils, so it should behave the same on Arch,
Debian, Ubuntu, and Fedora. It has been tested on Arch.

If you would rather do the steps by hand, or want to understand what the
script did, read on.

## Generating the model with Ollama

1. Pull the base model:

   ```sh
   ollama pull qwen2.5:7b
   ```

2. Build the wrapper model from the Modelfile for the profile you want
   (`Modelfile.max` or `Modelfile.light`):

   ```sh
   cd voxtype-llm-wrapper
   ollama create voxtype-llm-wrapper -f Modelfile.max
   ```

3. Confirm it works by piping some messy dictation through it:

   ```sh
   echo "um so let's meet tuesday no wait wednesday at four" | ollama run --nowordwrap voxtype-llm-wrapper
   ```

   Expected output:

   ```
   So, let's meet Wednesday at four.
   ```

Re-run `ollama create` any time you change the prompt or profile. The
existing model is replaced in place.

## Using it with voxtype

voxtype can pipe every transcription through an external command before typing
it out. Point that command at the model you just created.

Open `~/.config/voxtype/config.toml` and add (or edit) the post-processing
section under `[output]`:

```toml
[output.post_process]
command = "ollama run --nowordwrap voxtype-llm-wrapper"
timeout_ms = 30000
trim = true
fallback_on_empty = true
```

What each setting does:

| Key | Purpose |
| --- | --- |
| `command` | Shell command that receives the transcript on stdin and prints the cleaned text on stdout. |
| `timeout_ms` | How long to wait for the LLM. Raise this on slow hardware. If it times out, voxtype types the original transcript. |
| `trim` | Strip leading and trailing whitespace from the model output. |
| `fallback_on_empty` | If the model returns nothing, type the original transcript instead of nothing. |

Then restart the voxtype daemon so it picks up the change:

```sh
voxtype daemon
```

Or, if you run it as a systemd user service:

```sh
systemctl --user restart voxtype
```

Press your voxtype hotkey, dictate, and the cleaned text is typed at the
cursor. On any failure (Ollama not running, timeout, error) voxtype falls back
to the raw Whisper transcript, so enabling this never blocks dictation.

### Keeping the model warm

Ollama unloads a model after a few minutes idle, and the first request after
that pays a load cost of several seconds. To keep it resident, set a longer
keep-alive for the Ollama server, for example in the systemd override or your
shell environment:

```sh
OLLAMA_KEEP_ALIVE=24h
```

## Choosing a base model

To try a base model that is not one of the two profiles, pass it to
`setup.sh` as described above, or add a new file under `profiles/` with a
`FROM` line and any parameters, then run `./gen-modelfiles.sh` to render its
Modelfile.

Smaller models are faster but more likely to answer questions instead of
editing them, or to drop content. Run `./test.sh` before relying on a new
base, and check the base model's license if you need commercial use; model
families do not always license every size the same way.

## How the Modelfiles work

- `system_prompt.txt` holds the editing rules and the contextual formatting
  rules for emails, messages, and lists. It becomes the `SYSTEM` block.
- `examples.tsv` holds raw-dictation / edited-output pairs. Each one is
  rendered as a `MESSAGE user` / `MESSAGE assistant` turn, so the model sees
  the examples as real conversation history rather than as text inside the
  prompt. Small models follow this far better: with the examples inline as
  "Input:/Output:" text, the `light` model copied the `Output:` label into
  its answers and passed 15 of 22 test cases; as message turns it passed 21.
  The examples are the most effective lever if you want to change behaviour;
  add a pair that shows the edit you want, and add a different hold-out case
  to `test-cases.tsv` so the test still proves something.
- `profiles/<name>` holds the `FROM` line and parameters for one profile.
- `gen-modelfiles.sh` combines the three into `Modelfile.<name>`. The
  rendered Modelfiles are committed so the manual `ollama create` path works
  without running anything, but they are generated; edit the sources and
  re-run the script (`setup.sh` does this automatically).
- `temperature 0.0` makes output deterministic, so the same dictation always
  produces the same edit.
- `num_ctx 4096` is plenty for voxtype's default 60-second recording limit.

## Troubleshooting

- **Text is typed unchanged.** The post-process command failed or timed out.
  Run the `echo ... | ollama run` test above to check that Ollama is up and the
  model exists, and run `voxtype -v daemon` to see the error.
- **Nothing is typed.** Set `fallback_on_empty = true` so an empty model
  response falls back to the raw transcript.
- **The model answers instead of editing.** Add a pair to `examples.tsv`
  showing the exact phrasing being preserved, rebuild, and run `./test.sh`.
- **Long delay before text appears.** The model is being loaded on each
  request. See [Keeping the model warm](#keeping-the-model-warm).
